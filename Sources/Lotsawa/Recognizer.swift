/// A trampoline typelias that lets us create `Recognizer`'s `Grammar` type.
typealias Grammar_<RawSymbol: Hashable> = Grammar<RawSymbol>

/// A position in the source text; also an Earleme ID.
typealias SourcePosition = Int

/// A process that creates the parse forest for a token stream with respect to a `Grammar`.
public struct Recognizer<RawSymbol: Hashable> {
  fileprivate typealias Grammar = Grammar_<RawSymbol>

  /// A partially-completed parse (AKA an Earley item).
  fileprivate struct PartialParse {
    /// The positions in ruleStore of yet-to-be recognized RHS symbols.
    let expected: Grammar.DottedRule

    /// The position in the token stream where the partially-parsed input begins.
    let start: SourcePosition
  }

  /// The grammar being recognized.
  private let g: Grammar

  /// Storage for all Earley items, grouped by Earleme.
  private typealias PartialParses = [PartialParse]

  /// Storage for all Leo items, grouped by Earleme.
  private typealias LeoItems = [(transition: Grammar.Symbol, parse: PartialParse)]

  /// All the partial parses, grouped by earleme.
  private var partialParses: [PartialParse] = []

  /// The position in `partialParses` and `leoItems` where each earleme begins.
  private var earlemeStart: [(earley: PartialParses.Index, leo: LeoItems.Index)] = []

  /// Leo items, per the MARPA paper.
  private var leoItems: LeoItems = []
}

extension Recognizer.PartialParse: Hashable {
  /// Creates an instance recognizing `g.lhs(expected)` with `g.postdotRHS(expected)` remaining to
  /// be parsed.
  init(expecting expected: Grammar<RawSymbol>.DottedRule, at start: SourcePosition) {
    self.expected = expected
    self.start = start
  }

  /// Returns `self`, but with the dot moved forward by one position.
  func advanced() -> Self { Self(expecting: expected.advanced, at: start) }

  /// `true` iff there are no symbols left to recognize on the RHS of `self.rule`.
  var isComplete: Bool { return expected.isComplete }
}


extension Recognizer {
  /// Creates an instance that recognizes the given grammar.
  public init(_ g: Lotsawa.Grammar<RawSymbol>) { self.g = g }

  /// Returns the next symbol to be recognized in `p`, or `nil` if `p.isComplete`.
  private func postdot(_ p: PartialParse) -> Grammar.Symbol? { g.postdot(p.expected) }

  /// Returns the LHS symbol of the rule `p` is recognizing.
  private func lhs(_ p: PartialParse) -> Grammar.Symbol { g.lhs(p.expected) }

  /// Adds `p` to the latest earleme if it is not already there.
  private mutating func insertEarley(_ p: PartialParse) {
    if !partialParses[currentEarlemeStart...].contains(p) { partialParses.append(p) }
  }

  /// Adds the Leo item (`s`, `p`) to the latest earleme if it is not already there.
  private mutating func insertLeo(_ p: PartialParse, transition s: Grammar.Symbol) {
    if let i = leoItems[currentLeoStart...].firstIndex(where: { l in l.transition == s }) {
      assert(leoItems[i].parse == p)
      return
    }
    leoItems.append((s, p))
  }

  /// Returns the Leo items for Earleme `l`.
  private func leoItems(at l: SourcePosition) -> LeoItems.SubSequence {
    l == currentEarleme ? leoItems[earlemeStart[l].leo...]
      : leoItems[earlemeStart[l].leo..<earlemeStart[l+1].leo]
  }

  /// Returns the partial parse for the Leo item at `i` with the given `transition` symbol.
  private func leoParse(at i: SourcePosition, transition: Grammar.Symbol) -> PartialParse? {
    leoItems(at: i).first { l in l.transition == transition }?.parse ?? nil
  }

  /// The earleme to which we're currently adding items.
  private var currentEarleme: Int { earlemeStart.count - 1 }

  /// The index in `partialParses` at which the Earley items in the current earleme begin.
  private var currentEarlemeStart: PartialParses.Index { earlemeStart.last!.earley }

  /// The index in `leoItems` at which the Leo items in the current earleme begin.
  private var currentLeoStart: LeoItems.Index { earlemeStart.last!.leo }

  /// Prepares `self` to recognize an input of length `n`.
  mutating func initialize(inputLength n: Int) {
    partialParses.removeAll(keepingCapacity: true)
    earlemeStart.removeAll(keepingCapacity: true)
    leoItems.removeAll(keepingCapacity: true)
    earlemeStart.reserveCapacity(n + 1)
    partialParses.reserveCapacity(n + 1)
    earlemeStart.append((earley: 0, leo: 0))
  }

  /// Recognizes the sequence of symbols in `source` as a parse of `start`.
  public mutating func recognize<Source: Collection>(_ source: Source, as start: RawSymbol) -> Bool
    where Source.Element == RawSymbol
  {
    let start = Grammar.Symbol.some(start)
    let source = source.lazy.map { s in Grammar.Symbol.some(s) }
    initialize(inputLength: source.count)

    for r in g.alternatives(start) {
      partialParses.append(PartialParse(expecting: r.dotted, at: 0))
    }

    // Recognize each token over its range in the source.
    var tokens = source.makeIterator()

    var i = 0
    while i != earlemeStart.count {
      var j = earlemeStart[i].earley // The partial parse within the current earleme

      while j < partialParses.count {
        let p = partialParses[j]
        if !p.isComplete { predict(p) }
        else { reduce(p) }
        addAnyLeoItem(p)
        j += 1
      }

      // scans
      if let t = tokens.next() { scan(t) }
      i += 1
    }
    return tokens.next() == nil
      && partialParses[currentEarlemeStart...].contains { p in
        p.start == 0 && p.isComplete && lhs(p) == start
      }
  }

  /// Adds partial parses initiating recognition of `postdot(p)` at the current earleme.
  private mutating func predict(_ p: PartialParse) {
    let s = postdot(p)!
    for rhs in g.alternatives(s) {
      insertEarley(PartialParse(expecting: rhs.dotted, at: currentEarleme))
      if s.isNulling { insertEarley(p.advanced()) }
    }
  }

  /// Performs Leo reduction on `p`
  private mutating func reduce(_ p: PartialParse) {
    if let predecessor = leoParse(at: p.start, transition: lhs(p)) {
      insertEarley(PartialParse(expecting: predecessor.expected, at: predecessor.start))
    }
    else {
      earleyReduce(p)
    }
  }

  /// Performs Earley reduction on p.
  private mutating func earleyReduce(_ p: PartialParse) {
    let s0 = lhs(p)

    /// Inserts partialParses[k].advanced() iff its postdot symbol is s0.
    func advanceIfPostdotS0(_ k: Int) {
      let p0 = partialParses[k]
      if postdot(p0) == s0 { insertEarley(p0.advanced()) }
    }

    if p.start != currentEarleme {
      for k in earlemeStart[p.start].earley..<earlemeStart[p.start + 1].earley {
        advanceIfPostdotS0(k)
      }
    }
    else { // TODO: can we eliminate this branch?
      var k = earlemeStart[p.start].earley
      while k < partialParses.count {
        advanceIfPostdotS0(k)
        k += 1
      }
    }
  }

  /// Advances any partial parses expecting `t` at the current earleme.
  private mutating func scan(_ t: Grammar.Symbol) {
    var found = false
    for j in partialParses[currentEarlemeStart...].indices {
      let p = partialParses[j]
      if postdot(p) == t {
        if !found { earlemeStart.append((partialParses.count, leoItems.count)) }
        found = true
        insertEarley(p.advanced())
      }
    }
  }

  private mutating func addAnyLeoItem(_ b: PartialParse) {
    if !isLeoEligible(b.expected) { return }
    let s = g.penult(b.expected)!
    insertLeo(leoPredecessor(b) ?? b.advanced(), transition: s)
  }

  private func leoPredecessor(_ b: PartialParse) -> PartialParse? {
    return leoParse(at: b.start, transition: lhs(b))
  }

  private func isPenultUnique(_ x: Grammar.Symbol) -> Bool {
    return partialParses[currentEarlemeStart...]
      .hasUniqueElement { p in g.penult(p.expected) == x }
  }

  private func isLeoUnique(_ x: Grammar.DottedRule) -> Bool {
    if let p = g.penult(x) { return isPenultUnique(p) }
    return false
  }

  private func isLeoEligible(_ x: Grammar.DottedRule) -> Bool {
    g.isRightRecursive(x) && isLeoUnique(x)
  }
}

extension Recognizer: CustomStringConvertible {
  public var description: String {
    var lines: [String] = []
    var i = -1
    for j in partialParses.indices {
      if earlemeStart.count > i + 1 && j == earlemeStart[i + 1].earley {
        i += 1
        lines.append("\n=== \(i) ===")
        for (k, v) in leoItems(at: i) {
          lines.append("  Leo \(k): \(description(v))")
        }
      }
      lines.append(description(partialParses[j]))
    }
    return lines.joined(separator: "\n")
  }

  private func description(_ p: PartialParse) -> String {
    "\(g.description(p.expected))\t(\(p.start))"
  }
}
