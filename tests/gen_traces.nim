import std/[times, os], fluffy/measure


proc startFrame() {.measure.} =
  sleep(10)

proc drawPart(part: int) {.measure.} =
  sleep(1)

proc drawObject(parts: int) {.measure.} =
  sleep(5)
  for part in 0 ..< parts:
    drawPart(part)

proc endFrame() {.measure.} =
  sleep(20)

proc drawFrame(a: int) {.measure.} =
  startFrame()
  for i in 0 ..< a:
    drawObject(i)
  endFrame()
  return

startTrace()
for i in 0 ..< 2:
  drawFrame(10)
endTrace()
dumpMeasures(0.0, "tmp/trace.json")