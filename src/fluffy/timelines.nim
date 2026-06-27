type
  TraceSpan* = object
    ## Timeline range in trace time units.
    start*: float
    finish*: float

proc contains*(parent, child: TraceSpan): bool =
  ## Return true when child starts and finishes inside parent.
  child.start >= parent.start and child.finish <= parent.finish

proc trimParents*(parents: var seq[TraceSpan], child: TraceSpan) =
  ## Remove parent spans that do not fully contain child.
  while parents.len > 0 and not parents[^1].contains(child):
    discard parents.pop()

proc nestingDepth*(parents: var seq[TraceSpan], child: TraceSpan): int =
  ## Trim parent spans and return the nesting depth for child.
  parents.trimParents(child)
  parents.len
