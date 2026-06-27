import
  fluffy/timelines

echo "Testing timeline nesting."

let
  outer = TraceSpan(start: 0.0, finish: 10.0)
  tiny = TraceSpan(start: 1.0, finish: 2.0)
  partialOverlap = TraceSpan(start: 1.999, finish: 6.0)
  inner = TraceSpan(start: 1.1, finish: 1.9)

doAssert outer.contains(tiny)
doAssert tiny.contains(inner)
doAssert not tiny.contains(partialOverlap)

var parents: seq[TraceSpan]

doAssert parents.nestingDepth(outer) == 0
parents.add(outer)

doAssert parents.nestingDepth(tiny) == 1
parents.add(tiny)

doAssert parents.nestingDepth(partialOverlap) == 1
parents.add(partialOverlap)

parents.setLen(0)

doAssert parents.nestingDepth(outer) == 0
parents.add(outer)

doAssert parents.nestingDepth(tiny) == 1
parents.add(tiny)

doAssert parents.nestingDepth(inner) == 2

echo "Timeline nesting OK."
