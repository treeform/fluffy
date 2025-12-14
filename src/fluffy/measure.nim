## Profile Tracing

import
  std/[macros, json, monotimes, strformat, strutils, tables, os],
  jsony

type
  ChromeTraceEvent = ref object
    ## Chrome Tracing Event.
    name: string
    ph: string      # Event type.
    ts: float       # Timestamp in microseconds.
    pid: int
    tid: int
    cat: string     # Optional, comma-separated
    args: JsonNode # Optional data
    dur: float      # Optional for "X" phase
    id: string      # Optional for linking
    tts: float      # Optional thread timestamp
    alloc: int      # Optional for allocation count
    deloc: int      # Optional for deallocation count
    mem: int        # Optional for memory usage

  ChromeTrace = ref object
    ## This must be set to "ns" for Chrome tracing to show properly.
    displayTimeUnit: string = "ns"
    traceEvents: seq[ChromeTraceEvent]

  MemCounters* = object
    allocCounter: int
    deallocCounter: int

  Event = object
    nameId: int
    ts: float
    dur: float
    alloc: int
    deloc: int
    mem: int

  Trace = ref object
    names: Table[int, string]
    events: seq[Event]

var
  nameIds: Table[string, int]
  tracingEnabled: bool
  traceStartTick: int
  tracePid: int
  traceTid: int
  traceCategory: string
  traceData: Trace
  traceStarts: seq[Event]

proc getTicks*(): int =
  ## Gets accurate time.
  when defined(emscripten):
    0
  else:
    getMonoTime().ticks.int

when not defined(nimTypeNames):
  {.hint: "-d:nimTypeNames must be to track allocations and deallocations".}
  
proc getAllocations(): int =
  ## Gets the number of allocations.
  when defined(nimTypeNames):
    (cast[MemCounters](getMemCounters())).allocCounter
  else:
    0

proc getDeallocations(): int =
  ## Gets the number of deallocations.
  when defined(nimTypeNames):
    (cast[MemCounters](getMemCounters())).deallocCounter
  else:
    0

proc getMemoryUsage(): int =
  ## Gets the memory usage.
  getOccupiedMem()

proc startTrace*(pid = 1, tid = 1, category = "measure") =
  ## Starts a chrome://tracing compatible capture and enables tracing.
  tracingEnabled = true
  traceStartTick = getTicks()
  tracePid = pid
  traceTid = tid
  traceCategory = category
  traceStarts.setLen(0)
  if traceData.isNil:
    traceData = Trace(events: @[])
  else:
    traceData.events.setLen(0)

  echo "Trace started"
  echo " trace events: ", traceData.events.len

proc endTrace*() =
  ## Ends tracing capture without writing to disk. Use dumpTrace to export.
  tracingEnabled = false

  echo "Trace ended"
  echo " trace events: ", traceData.events.len

proc setTraceEnabled*(on: bool) =
  ## Sets tracing enabled state without resetting buffers.
  tracingEnabled = on

proc measurePush*(what: string) =
  ## Used by {.measure.} pragma to push a measure section.
  if tracingEnabled:
    let now = getTicks().float
    let nameId =
      if what notin nameIds:
        let id = nameIds.len
        nameIds[what] = id
        id
      else:
        nameIds[what]
    traceStarts.add(Event(
      nameId: nameId,
      ts: now, 
      alloc: getAllocations(), 
      deloc: getDeallocations(),
      mem: getMemoryUsage()
    ))

proc measurePop*() =
  ## Used by {.measure.} pragma to pop a measure section.
  if tracingEnabled:
    let now = getTicks().float 
    let eventStart = traceStarts.pop()
    traceData.events.add(Event(
      nameId: eventStart.nameId,
      ts: eventStart.ts,
      dur: now - eventStart.ts,
      alloc: getAllocations() - eventStart.alloc,
      deloc: getDeallocations() - eventStart.deloc,
      mem: getMemoryUsage() - eventStart.mem
    ))

macro measure*(fn: untyped) =
  ## Macro that adds performance measurement to a function.
  let procName = fn[0].repr
  fn[6].insert 0, quote do:
    measurePush(`procName`)
    defer:
      measurePop()
  return fn

proc dumpMeasures*(overTotalMs = 0.0, tracePath = "") =
  ## Dumps performance measurements if total time exceeds threshold.
  if tracePath.len > 0 and not traceData.isNil:
    for (name, nameId) in nameIds.pairs:
      traceData.names[nameId] = name
    # let jsonText = toJson(traceData)
    # writeFile(tracePath, jsonText)
    # echo "Trace written to ", tracePath

    # Generate a Chrome Trace JSON file.
    var chromeTrace: ChromeTrace = ChromeTrace(
      displayTimeUnit: "ns"
    )
    let firstTs = traceData.events[0].ts
    for event in traceData.events:
      chromeTrace.traceEvents.add(ChromeTraceEvent(
        name: traceData.names[event.nameId],
        ph: "X",
        ts: (event.ts - firstTs) / 1000.0,
        pid: tracePid,
        tid: traceTid,
        cat: traceCategory,
        args: newJNull(),
        dur: event.dur / 1000.0,
        alloc: event.alloc,
        deloc: event.deloc,
        mem: event.mem
      ))
    let jsonText = toJson(chromeTrace)
    writeFile(tracePath, jsonText)
    echo "Trace written to ", tracePath