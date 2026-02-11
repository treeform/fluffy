import
  std/[algorithm, hashes, math, os, random, strformat, tables],
  bumpy, chroma, jsony, opengl, silky, vmath, windy

let builder = newAtlasBuilder(1024, 4)
builder.addDir("data/", "data/")
builder.addFont("data/IBMPlexSans-Regular.ttf", "H1", 32.0)
builder.addFont("data/IBMPlexSans-Regular.ttf", "Default", 18.0, subpixelSteps = 10)
builder.write("dist/atlas.png", "dist/atlas.json")
let window = newWindow(
  "Fluffy Nim Profiler",
  ivec2(1200, 800),
  vsync = false
)

makeContextCurrent(window)
loadExtensions()

let sk = newSilky("dist/atlas.png", "dist/atlas.json")

type
  AreaLayout = enum
    Horizontal
    Vertical

  Area = ref object
    layout: AreaLayout
    areas: seq[Area]
    panels: seq[Panel]
    split: float32
    selectedPanelNum: int
    rect: Rect # Calculated during draw.

  PanelDraw = proc(panel: Panel, frameId: string, contentPos: Vec2, contentSize: Vec2)

  Panel = ref object
    name: string
    parentArea: Area
    draw: PanelDraw

  AreaScan = enum
    Header
    Body
    North
    South
    East
    West

  TraceEvent = ref object
    name: string # Name of the function or region.
    ts: float # Timestamp in microseconds.
    dur: float # Duration in microseconds.
    alloc: int # Number of allocations.
    deloc: int # Number of deallocations.
    mem: int # Memory change in bytes.

  Trace = ref object
    displayTimeUnit: string = "ns"
    traceEvents: seq[TraceEvent]

  EventStats = object
    name: string
    totalTime: float
    selfTime: float
    count: int
    totalAlloc: int
    totalDeloc: int
    totalMem: int
    selfMem: int

  TreemapItem = object
    eventIndex: int
    name: string
    value: float

  TreemapGroup = object
    name: string
    totalValue: float
    items: seq[TreemapItem]

const
  AreaHeaderHeight = 32.0
  AreaMargin = 6.0
  BackgroundColor = parseHtmlColor("#222222").rgbx
  FlatUIColors = [
    parseHtmlColor("#1abc9c").rgbx,
    parseHtmlColor("#16a085").rgbx,
    parseHtmlColor("#2ecc71").rgbx,
    parseHtmlColor("#27ae60").rgbx,
    parseHtmlColor("#3498db").rgbx,
    parseHtmlColor("#2980b9").rgbx,
    parseHtmlColor("#9b59b6").rgbx,
    parseHtmlColor("#8e44ad").rgbx,
    parseHtmlColor("#34495e").rgbx,
    parseHtmlColor("#2c3e50").rgbx,
    parseHtmlColor("#f1c40f").rgbx,
    parseHtmlColor("#f39c12").rgbx,
    parseHtmlColor("#e67e22").rgbx,
    parseHtmlColor("#d35400").rgbx,
    parseHtmlColor("#e74c3c").rgbx,
    parseHtmlColor("#c0392b").rgbx,
  ]

var
  rootArea: Area
  dragArea: Area # For resizing splits.
  dragPanel: Panel # For moving panels.
  dropHighlight: Rect
  showDropHighlight: bool

  maybeDragStartPos: Vec2
  maybeDragPanel: Panel

  prevMem: int
  prevNumAlloc: int

  trace: Trace
  traceFilePath: string = "traces/example_trace.json"

  selectedEventIndex: int = -1
  rangeSelectionActive: bool = false
  rangeSelectionStart: float = 0.0
  rangeSelectionEnd: float = 0.0
  rangeSelectionDragging: bool = false
  lastRangeForStats: tuple[active: bool, start: float, finish: float] = (false, 0.0, 0.0)

  tableSortColumn: string = ""
  tableSortAscending: bool = true
  timelineZoom: float = 1.0
  timelinePanOffset: float = 0.0
  timelinePanning: bool = false
  timelinePanStartPos: Vec2
  timelinePanStartOffset: float

  cachedTraceStats: seq[EventStats]
  traceStatsComputed = false
  lastSelectedEventIndex = -1
  treemapGroups: seq[TreemapGroup]
  treemapLastRange: tuple[active: bool, start: float, finish: float]
  treemapNeedsUpdate = true
  eventSelfMems: seq[int]

proc snapToPixels(rect: Rect): Rect =
  ## Snap a rectangle to pixel boundaries.
  rect(
    rect.x.round,
    rect.y.round,
    max(1, rect.w.round),
    max(1, rect.h.round)
  )

proc movePanels*(area: Area, panels: seq[Panel])
proc clear*(area: Area) =
  ## Clear the area.
  for panel in area.panels:
    panel.parentArea = nil
  for subarea in area.areas:
    subarea.clear()
  area.panels.setLen(0)
  area.areas.setLen(0)

proc removeBlankAreas*(area: Area) =
  ## Remove blank areas recursively.
  if area.areas.len > 0:
    assert area.areas.len == 2
    if area.areas[0].panels.len == 0 and area.areas[0].areas.len == 0:
      if area.areas[1].panels.len > 0:
        area.movePanels(area.areas[1].panels)
        area.areas.setLen(0)
      elif area.areas[1].areas.len > 0:
        let oldAreas = area.areas
        area.areas = area.areas[1].areas
        area.split = oldAreas[1].split
        area.layout = oldAreas[1].layout
      else:
        discard
    elif area.areas[1].panels.len == 0 and area.areas[1].areas.len == 0:
      if area.areas[0].panels.len > 0:
        area.movePanels(area.areas[0].panels)
        area.areas.setLen(0)
      elif area.areas[0].areas.len > 0:
        let oldAreas = area.areas
        area.areas = area.areas[0].areas
        area.split = oldAreas[0].split
        area.layout = oldAreas[0].layout
      else:
        discard

    for subarea in area.areas:
      removeBlankAreas(subarea)

proc addPanel*(area: Area, name: string, draw: PanelDraw) =
  ## Add a panel to the area.
  let panel = Panel(name: name, parentArea: area, draw: draw)
  area.panels.add(panel)

proc movePanel*(area: Area, panel: Panel) =
  ## Move a panel to this area.
  let idx = panel.parentArea.panels.find(panel)
  if idx != -1:
    panel.parentArea.panels.delete(idx)
  area.panels.add(panel)
  panel.parentArea = area

proc insertPanel*(area: Area, panel: Panel, index: int) =
  ## Insert a panel into this area at a specific index.
  let idx = panel.parentArea.panels.find(panel)
  var finalIndex = index

  # If moving within the same area, adjust index if we're moving forward.
  if panel.parentArea == area and idx != -1:
    if idx < index:
      finalIndex = index - 1

  if idx != -1:
    panel.parentArea.panels.delete(idx)

  # Clamp index to be safe.
  finalIndex = clamp(finalIndex, 0, area.panels.len)

  area.panels.insert(panel, finalIndex)
  panel.parentArea = area
  # Update selection to the new panel position.
  area.selectedPanelNum = finalIndex

proc getTabInsertInfo(area: Area, mousePos: Vec2): (int, Rect) =
  ## Get the insert information for a tab.
  var x = area.rect.x + 4
  let headerH = AreaHeaderHeight

  # If no panels, insert at 0.
  if area.panels.len == 0:
    return (0, rect(x, area.rect.y + 4, 4, headerH - 4))

  var bestIndex = 0
  var minDist = float32.high
  var bestX = x

  # Check before first tab (index 0).
  let dist0 = abs(mousePos.x - x)
  minDist = dist0
  bestX = x
  bestIndex = 0

  for i, panel in area.panels:
    let textSize = sk.getTextSize("Default", panel.name)
    let tabW = textSize.x + 16

    # The gap after this tab (index i + 1).
    let gapX = x + tabW + 2
    let dist = abs(mousePos.x - gapX)
    if dist < minDist:
      minDist = dist
      bestIndex = i + 1
      bestX = gapX

    x += tabW + 2

  return (bestIndex, rect(bestX - 2, area.rect.y + 4, 4, headerH - 4))

proc movePanels*(area: Area, panels: seq[Panel]) =
  ## Move multiple panels to this area.
  var panelList = panels # Copy.
  for panel in panelList:
    area.movePanel(panel)

proc split*(area: Area, layout: AreaLayout) =
  ## Split the area.
  let
    area1 = Area(rect: area.rect) # Inherit rect initially.
    area2 = Area(rect: area.rect)
  area.layout = layout
  area.split = 0.5
  area.areas.add(area1)
  area.areas.add(area2)

proc scan*(area: Area): (Area, AreaScan, Rect) =
  ## Scan the area to find the target under mouse.
  let mousePos = window.mousePos.vec2
  var
    targetArea: Area
    areaScan: AreaScan
    resRect: Rect

  proc visit(area: Area) =
    if not mousePos.overlaps(area.rect):
      return

    if area.areas.len > 0:
      for subarea in area.areas:
        visit(subarea)
    else:
      let
        headerRect = rect(
          area.rect.xy,
          vec2(area.rect.w, AreaHeaderHeight)
        )
        bodyRect = rect(
          area.rect.xy + vec2(0, AreaHeaderHeight),
          vec2(area.rect.w, area.rect.h - AreaHeaderHeight)
        )
        northRect = rect(
          area.rect.xy + vec2(0, AreaHeaderHeight),
          vec2(area.rect.w, area.rect.h * 0.2)
        )
        southRect = rect(
          area.rect.xy + vec2(0, area.rect.h * 0.8),
          vec2(area.rect.w, area.rect.h * 0.2)
        )
        eastRect = rect(
          area.rect.xy + vec2(area.rect.w * 0.8, 0) + vec2(0, AreaHeaderHeight),
          vec2(area.rect.w * 0.2, area.rect.h - AreaHeaderHeight)
        )
        westRect = rect(
          area.rect.xy + vec2(0, 0) + vec2(0, AreaHeaderHeight),
          vec2(area.rect.w * 0.2, area.rect.h - AreaHeaderHeight)
        )

      if mousePos.overlaps(headerRect):
        areaScan = Header
        resRect = headerRect
      elif mousePos.overlaps(northRect):
        areaScan = North
        resRect = northRect
      elif mousePos.overlaps(southRect):
        areaScan = South
        resRect = southRect
      elif mousePos.overlaps(eastRect):
        areaScan = East
        resRect = eastRect
      elif mousePos.overlaps(westRect):
        areaScan = West
        resRect = westRect
      elif mousePos.overlaps(bodyRect):
        areaScan = Body
        resRect = bodyRect

      targetArea = area

  visit(rootArea)
  return (targetArea, areaScan, resRect)

proc drawAreaRecursive(area: Area, r: Rect) =
  area.rect = r.snapToPixels()

  if area.areas.len > 0:
    let m = AreaMargin / 2
    if area.layout == Horizontal:
      # Top/Bottom.
      let splitPos = r.h * area.split

      # Handle split resizing.
      let splitRect = rect(r.x, r.y + splitPos - 2, r.w, 4)

      if dragArea == nil and window.mousePos.vec2.overlaps(splitRect):
        sk.cursor = Cursor(kind: ResizeUpDownCursor)
        if window.buttonPressed[MouseLeft]:
          dragArea = area

      let r1 = rect(r.x, r.y, r.w, splitPos - m)
      let r2 = rect(r.x, r.y + splitPos + m, r.w, r.h - splitPos - m)
      drawAreaRecursive(area.areas[0], r1)
      drawAreaRecursive(area.areas[1], r2)

    else:
      # Left/Right.
      let splitPos = r.w * area.split

      let splitRect = rect(r.x + splitPos - 2, r.y, 4, r.h)

      if dragArea == nil and window.mousePos.vec2.overlaps(splitRect):
        sk.cursor = Cursor(kind: ResizeLeftRightCursor)
        if window.buttonPressed[MouseLeft]:
          dragArea = area

      let r1 = rect(r.x, r.y, splitPos - m, r.h)
      let r2 = rect(r.x + splitPos + m, r.y, r.w - splitPos - m, r.h)
      drawAreaRecursive(area.areas[0], r1)
      drawAreaRecursive(area.areas[1], r2)

  elif area.panels.len > 0:
    # Draw Panel.
    if area.selectedPanelNum > area.panels.len - 1:
      area.selectedPanelNum = area.panels.len - 1

    # Draw Header.
    let headerRect = rect(r.x, r.y, r.w, AreaHeaderHeight)
    sk.draw9Patch("panel.header.9patch", 3, headerRect.xy, headerRect.wh)

    # Draw Tabs.
    var x = r.x + 4
    sk.pushClipRect(rect(r.x, r.y, r.w - 2, AreaHeaderHeight))
    for i, panel in area.panels:
      let textSize = sk.getTextSize("Default", panel.name)
      let tabW = textSize.x + 16
      let tabRect = rect(x, r.y + 4, tabW, AreaHeaderHeight - 4)

      let isSelected = i == area.selectedPanelNum
      let isHovered = window.mousePos.vec2.overlaps(tabRect)

      # Handle Tab Clicks and Dragging.
      if isHovered:
        if window.buttonPressed[MouseLeft]:
          area.selectedPanelNum = i
          # Only start dragging if the mouse moves 10 pixels.
          maybeDragStartPos = window.mousePos.vec2
          maybeDragPanel = panel
        elif window.buttonDown[MouseLeft] and dragPanel == panel:
          # Dragging started.
          discard

      if window.buttonDown[MouseLeft]:
        if maybeDragPanel != nil and (maybeDragStartPos - window.mousePos.vec2).length() > 10:
          dragPanel = maybeDragPanel
          maybeDragStartPos = vec2(0, 0)
          maybeDragPanel = nil
      else:
        maybeDragStartPos = vec2(0, 0)
        maybeDragPanel = nil

      if isSelected:
        sk.draw9Patch("panel.tab.selected.9patch", 3, tabRect.xy, tabRect.wh, rgbx(255, 255, 255, 255))
      elif isHovered:
        sk.draw9Patch("panel.tab.hover.9patch", 3, tabRect.xy, tabRect.wh, rgbx(255, 255, 255, 255))
      else:
        sk.draw9Patch("panel.tab.9patch", 3, tabRect.xy, tabRect.wh)

      discard sk.drawText("Default", panel.name, vec2(x + 8, r.y + 4 + 2), rgbx(255, 255, 255, 255))

      x += tabW + 2
    sk.popClipRect()

    # Draw Content.
    let contentRect = rect(r.x, r.y + AreaHeaderHeight, r.w, r.h - AreaHeaderHeight)
    let activePanel = area.panels[area.selectedPanelNum]
    let frameId = "panel:" & $cast[uint](activePanel)
    let contentPos = vec2(contentRect.x, contentRect.y)
    let contentSize = vec2(contentRect.w, contentRect.h)

    activePanel.draw(activePanel, frameId, contentPos, contentSize)

proc drawPanels() =
  # Update Dragging Split.
  if dragArea != nil:
    if not window.buttonDown[MouseLeft]:
      dragArea = nil
    else:
      if dragArea.layout == Horizontal:
        sk.cursor = Cursor(kind: ResizeUpDownCursor)
        dragArea.split = (window.mousePos.vec2.y - dragArea.rect.y) / dragArea.rect.h
      else:
        sk.cursor = Cursor(kind: ResizeLeftRightCursor)
        dragArea.split = (window.mousePos.vec2.x - dragArea.rect.x) / dragArea.rect.w
      dragArea.split = clamp(dragArea.split, 0.1, 0.9)

  # Update Dragging Panel.
  showDropHighlight = false
  if dragPanel != nil:
    if not window.buttonDown[MouseLeft]:
      # Drop.
      let (targetArea, areaScan, _) = rootArea.scan()
      if targetArea != nil:
        case areaScan:
        of Header:
          let (idx, _) = targetArea.getTabInsertInfo(window.mousePos.vec2)
          targetArea.insertPanel(dragPanel, idx)
        of Body:
          targetArea.movePanel(dragPanel)
        of North:
          targetArea.split(Horizontal)
          targetArea.areas[0].movePanel(dragPanel)
          targetArea.areas[1].movePanels(targetArea.panels)
        of South:
          targetArea.split(Horizontal)
          targetArea.areas[1].movePanel(dragPanel)
          targetArea.areas[0].movePanels(targetArea.panels)
        of East:
          targetArea.split(Vertical)
          targetArea.areas[1].movePanel(dragPanel)
          targetArea.areas[0].movePanels(targetArea.panels)
        of West:
          targetArea.split(Vertical)
          targetArea.areas[0].movePanel(dragPanel)
          targetArea.areas[1].movePanels(targetArea.panels)

        rootArea.removeBlankAreas()
      dragPanel = nil
    else:
      # Dragging the panel to a new location.
      let (targetArea, areaScan, rect) = rootArea.scan()
      dropHighlight = rect
      showDropHighlight = true

      if targetArea != nil and areaScan == Header:
         let (_, highlightRect) = targetArea.getTabInsertInfo(window.mousePos.vec2)
         dropHighlight = highlightRect

  # Draw Areas.
  drawAreaRecursive(rootArea, rect(0, 1, window.size.x.float32, window.size.y.float32))

  # Draw Drop Highlight.
  if showDropHighlight and dragPanel != nil:
    sk.drawRect(dropHighlight.xy, dropHighlight.wh, rgbx(255, 255, 0, 100))

    # Draw dragging ghost.
    let label = dragPanel.name
    let textSize = sk.getTextSize("Default", label)
    let size = textSize + vec2(16, 8)
    sk.draw9Patch("tooltip.9patch", 4, window.mousePos.vec2 + vec2(10, 10), size, rgbx(255, 255, 255, 200))
    discard sk.drawText("Default", label, window.mousePos.vec2 + vec2(18, 14), rgbx(255, 255, 255, 255))

proc nameToColor(name: string): ColorRGBX =
  ## Map a name to a deterministic color from the palette.
  let hash = abs(name.hash.int)
  FlatUIColors[hash mod FlatUIColors.len]

proc calculateNiceInterval(visibleDuration: float, targetTicks: int = 10): float =
  ## Calculate a "nice" interval for timeline ticks (1, 2, 5, 10, 20, 50, etc.)
  let roughInterval = visibleDuration / targetTicks.float
  let magnitude = pow(10.0, floor(log10(roughInterval)))
  let normalized = roughInterval / magnitude

  # Choose 1, 2, or 5 based on normalized value.
  let niceMult =
    if normalized <= 1.5: 1.0
    elif normalized <= 3.0: 2.0
    elif normalized <= 7.0: 5.0
    else: 10.0

  return niceMult * magnitude

proc formatTickTime(tickInterval: float, tickTime: float): string =
  ## Format a tick time as a human-readable millisecond string.
  if tickInterval >= 100.0:
    &"{(tickTime / 1000.0):.1f}ms"
  elif tickInterval >= 10.0:
    &"{(tickTime / 1000.0):.2f}ms"
  elif tickInterval >= 1.0:
    &"{(tickTime / 1000.0):.3f}ms"
  else:
    &"{(tickTime / 1000.0):.4f}ms"

proc formatBytes(bytes: int): string =
  ## Format bytes into human-readable string.
  if bytes >= 1_073_741_824:
    &"{bytes.float / 1_073_741_824.0:.1f} GB"
  elif bytes >= 1_048_576:
    &"{bytes.float / 1_048_576.0:.1f} MB"
  elif bytes >= 1024:
    &"{bytes.float / 1024.0:.1f} KB"
  else:
    &"{bytes} B"

proc drawTraceTimeline(panel: Panel, frameId: string, contentPos: Vec2, contentSize: Vec2) =
  ## Draw the trace timeline panel with ruler, events, and range selection.
  frame(frameId, contentPos, contentSize):
    let mousePos = window.mousePos.vec2
    let contentRect = rect(contentPos.x, contentPos.y, contentSize.x, contentSize.y)
    let isMouseOver = mousePos.overlaps(contentRect)
    # Clip all drawing to the content area with a 2 pixel inset.
    let clipRect = rect(
      contentPos.x + 2, contentPos.y + 2,
      contentSize.x - 4, contentSize.y - 4
    )
    sk.pushClipRect(clipRect)

    # Handle mouse wheel zooming (relative to mouse position).
    if isMouseOver and window.scrollDelta.y != 0 and not timelinePanning:
      let zoomFactor = if window.scrollDelta.y > 0: 1.1 else: 0.9
      let oldZoom = timelineZoom
      timelineZoom *= zoomFactor
      timelineZoom = max(0.0001, min(timelineZoom, 100000.0))  # Clamp zoom.

      # Calculate mouse position relative to content area (normalized 0-1).
      let mouseRelX = (mousePos.x - contentPos.x) / contentSize.x

      # Adjust pan offset so the point under the mouse stays fixed.
      # The formula: keep the same world position under the mouse.
      let worldPosBeforeZoom = (mouseRelX - timelinePanOffset) / oldZoom
      let worldPosAfterZoom = (mouseRelX - timelinePanOffset) / timelineZoom
      timelinePanOffset += (worldPosAfterZoom - worldPosBeforeZoom) * timelineZoom

    # Handle panning with middle mouse button.
    if isMouseOver and window.buttonPressed[MouseMiddle] and dragPanel == nil:
      timelinePanning = true
      timelinePanStartPos = mousePos
      timelinePanStartOffset = timelinePanOffset

    if timelinePanning:
      if window.buttonDown[MouseMiddle]:
        let delta = mousePos.x - timelinePanStartPos.x
        timelinePanOffset = timelinePanStartOffset + (delta / contentSize.x)
      else:
        timelinePanning = false

    # Compute the total duration of the trace.
    let at = contentPos + vec2(0, 20)
    var firstTs = trace.traceEvents[0].ts
    var lastTs = trace.traceEvents[trace.traceEvents.len - 1].ts + trace.traceEvents[trace.traceEvents.len - 1].dur
    for event in trace.traceEvents:
      firstTs = min(firstTs, event.ts)
      lastTs = max(lastTs, event.ts + event.dur)
    let duration = lastTs - firstTs

    # Apply zoom and pan to the scale calculation.
    let baseScale = contentSize.x / duration
    let scale = baseScale * timelineZoom
    let panPixels = timelinePanOffset * contentSize.x

    # Calculate visible time range for ruler.
    let visibleStartTime = firstTs - (panPixels / scale)
    let visibleEndTime = visibleStartTime + (contentSize.x / scale)
    let visibleDuration = visibleEndTime - visibleStartTime

    # Draw timeline ruler.
    let rulerHeight = 40.0
    let rulerY = contentPos.y
    sk.drawRect(vec2(contentPos.x, rulerY), vec2(contentSize.x, rulerHeight), rgbx(40, 40, 40, 255))

    # Calculate nice tick interval.
    let tickInterval = calculateNiceInterval(visibleDuration)

    # Find first tick that's visible.
    let firstTick = ceil(visibleStartTime / tickInterval) * tickInterval

    # Draw ticks and labels.
    var tickTime = firstTick
    while tickTime <= visibleEndTime:
      let tickX = (tickTime - firstTs) * scale + panPixels + contentPos.x

      if tickX >= contentPos.x and tickX <= contentPos.x + contentSize.x:
        # Draw tick mark.
        sk.drawRect(vec2(tickX, rulerY + rulerHeight - 8), vec2(1, 8), rgbx(150, 150, 150, 255))

        # Format and draw label.
        let label = formatTickTime(tickInterval, tickTime)

        let labelSize = sk.getTextSize("Default", label)
        discard sk.drawText("Default", label, vec2(tickX - labelSize.x / 2, rulerY + 2), rgbx(200, 200, 200, 255))

      tickTime += tickInterval

    const Height = 28.float

    # Handle range selection on ruler.
    let rulerRect = rect(contentPos.x, rulerY, contentSize.x, rulerHeight)

    if mousePos.overlaps(rulerRect) and window.buttonPressed[MouseLeft] and not timelinePanning and dragPanel == nil:
      # Start range selection.
      let mouseTime = firstTs + ((mousePos.x - contentPos.x - panPixels) / scale)
      rangeSelectionStart = mouseTime
      rangeSelectionEnd = mouseTime
      rangeSelectionDragging = true
      rangeSelectionActive = true

    if rangeSelectionDragging:
      if window.buttonDown[MouseLeft]:
        # Update range end position.
        let mouseTime = firstTs + ((mousePos.x - contentPos.x - panPixels) / scale)
        rangeSelectionEnd = mouseTime
      else:
        # Finished dragging.
        rangeSelectionDragging = false

    # Draw range selection rectangle.
    if rangeSelectionActive:
      let rangeStart = min(rangeSelectionStart, rangeSelectionEnd)
      let rangeEnd = max(rangeSelectionStart, rangeSelectionEnd)
      let rangeStartX = (rangeStart - firstTs) * scale + panPixels + contentPos.x
      let rangeEndX = (rangeEnd - firstTs) * scale + panPixels + contentPos.x
      let rangeWidth = rangeEndX - rangeStartX
      let rangeDuration = rangeEnd - rangeStart

      # Draw the range highlight behind everything (but after ruler).
      sk.drawRect(vec2(rangeStartX, contentPos.y), vec2(rangeWidth, contentSize.y), rgbx(40, 40, 40, 40))

      # Draw the range duration label.
      let durationLabel = formatTickTime(tickInterval, rangeDuration)

      let labelSize = sk.getTextSize("Default", durationLabel)
      let labelX = rangeStartX + (rangeWidth - labelSize.x) / 2  # Center the label.
      let labelY = contentPos.y + rulerHeight - 5

      # Draw background for label.
      sk.draw9Patch("tooltip.9patch", 4, vec2(labelX - 4, labelY - 2), vec2(labelSize.x + 8, labelSize.y + 4), rgbx(0, 0, 0, 200))

      # Draw label text.
      discard sk.drawText("Default", durationLabel, vec2(labelX, labelY), rgbx(255, 255, 255, 255))

    # Handle event selection on click.
    var clickedEventIndex = -1
    var clickedOnEvent = false
    if isMouseOver and window.buttonPressed[MouseLeft] and not timelinePanning and dragPanel == nil and not rangeSelectionDragging:
      # Check if we clicked on any event.
      var stack2: seq[tuple[event: TraceEvent, index: int]]
      for i, event in trace.traceEvents:
        while stack2.len > 0 and stack2[^1].event.ts + stack2[^1].event.dur <= event.ts:
          discard stack2.pop()

        let x = (event.ts - firstTs) * scale + panPixels
        let w = max(1, event.dur * scale)
        let level = stack2.len.float * Height + rulerHeight

        # Use 'at' offset to match drawing coordinates.
        let eventRect = rect(at.x + x, at.y + level, w, Height)
        if mousePos.overlaps(eventRect):
          clickedEventIndex = i
          clickedOnEvent = true

        stack2.add((event: event, index: i))

      # Update selection.
      if clickedEventIndex >= 0:
        selectedEventIndex = clickedEventIndex
      else:
        # Clicked outside any event, deselect.
        selectedEventIndex = -1

        # Also clear range selection if clicked outside ruler and events.
        if not mousePos.overlaps(rulerRect):
          rangeSelectionActive = false

    var stack: seq[TraceEvent]
    var prevBounds = rect(0, 0, 0, 0)
    var skips = 0
    var hoveredEventIndex = -1
    var hoveredEventRect: Rect
    for i, event in trace.traceEvents:
      while stack.len > 0 and stack[^1].ts + stack[^1].dur <= event.ts:
        discard stack.pop()
      let x = (event.ts - firstTs) * scale + panPixels
      let w = max(1, event.dur * scale)
      let level = stack.len.float * Height + rulerHeight;

      # Only draw if visible in the viewport.
      if x + w >= 0 and x <= contentSize.x:
        var color = nameToColor(event.name)

        # Highlight selected event.
        if i == selectedEventIndex:
          # Draw selection highlight.
          color = rgbx(200, 200, 200, 255)

        let bounds = rect(at.x + x, at.y + level, w, Height).snapToPixels()

        if bounds.x == prevBounds.x and bounds.y == prevBounds.y and
          bounds.w == prevBounds.w and bounds.h == prevBounds.h:
          # As an optimization, skip drawing in the same place twice.
          # This is really common when events get very tiny.
          inc skips
        else:
          prevBounds = bounds
          sk.drawRect(bounds.xy, bounds.wh, color)
          if w > 30:
            discard sk.drawText("Default", event.name, at + vec2(x, level), rgbx(255, 255, 255, 255), maxWidth = w)

        # Track hover on visible events.
        if isMouseOver and mousePos.overlaps(bounds):
          hoveredEventIndex = i
          hoveredEventRect = bounds

      stack.add(event)
    sk.popClipRect()

    # Draw hover highlight and tooltip outside the clip rect.
    if hoveredEventIndex >= 0:
      sk.drawRect(hoveredEventRect.xy, hoveredEventRect.wh, rgbx(128, 128, 128, 128))
      let event = trace.traceEvents[hoveredEventIndex]
      let dur = &"{event.dur / 1000:.4f}ms"
      let tip = event.name & " " & dur &
        (if event.alloc > 0: " " & $event.alloc & " allocs" else: "") &
        (if event.mem != 0: " " & formatBytes(event.mem) else: "")
      let tipSize = sk.getTextSize("Default", tip)
      let tipPos = mousePos + vec2(12, 12)
      sk.draw9Patch(
        "tooltip.9patch", 4,
        tipPos - vec2(4, 2),
        vec2(tipSize.x + 8, tipSize.y + 4),
        rgbx(0, 0, 0, 220)
      )
      discard sk.drawText("Default", tip, tipPos, rgbx(255, 255, 255, 255))

proc computeEventSelfMems() =
  ## Compute self memory for each event (total mem minus direct children's mem).
  ## Parents record the sum of their children's memory, so self mem subtracts
  ## each direct child's mem from the parent, analogous to self time.
  eventSelfMems = newSeq[int](trace.traceEvents.len)
  for i in 0..<trace.traceEvents.len:
    eventSelfMems[i] = trace.traceEvents[i].mem

  # Use a stack to track parent-child relationships.
  var stack: seq[int] # Stack of event indices.
  for i, event in trace.traceEvents:
    while stack.len > 0 and
        trace.traceEvents[stack[^1]].ts + trace.traceEvents[stack[^1]].dur <= event.ts:
      discard stack.pop()

    # If there's a parent on the stack, subtract this event's mem from it.
    if stack.len > 0:
      eventSelfMems[stack[^1]] -= event.mem

    stack.add(i)

proc computeTraceStats(): seq[EventStats] =
  ## Pre-compute trace statistics for all events.
  var statsMap: Table[string, EventStats]

  # Check if we're filtering to a single event.
  let isSingleEvent = selectedEventIndex >= 0

  # Get the active range (if any).
  let rangeStart = if rangeSelectionActive: min(rangeSelectionStart, rangeSelectionEnd) else: 0.0
  let rangeEnd = if rangeSelectionActive: max(rangeSelectionStart, rangeSelectionEnd) else: 0.0

  # Helper to clip event time to range.
  proc clipEventToRange(eventStart, eventEnd: float): tuple[start: float, finish: float, duration: float] =
    ## Clip event time range to the active selection range.
    if not rangeSelectionActive:
      return (eventStart, eventEnd, eventEnd - eventStart)

    let clippedStart = max(eventStart, rangeStart)
    let clippedEnd = min(eventEnd, rangeEnd)

    if clippedStart >= clippedEnd:
      # Event doesn't overlap with range.
      return (0.0, 0.0, 0.0)

    return (clippedStart, clippedEnd, clippedEnd - clippedStart)

  # First pass: compute total time for each event name (or single event).
  if isSingleEvent:
    # Just the selected event.
    let event = trace.traceEvents[selectedEventIndex]
    let eventEnd = event.ts + event.dur
    let clipped = clipEventToRange(event.ts, eventEnd)

    if clipped.duration > 0:
      statsMap[event.name] = EventStats(
        name: event.name,
        totalTime: clipped.duration,
        selfTime: 0.0,
        count: 1,
        totalAlloc: event.alloc,
        totalDeloc: event.deloc,
        totalMem: event.mem,
        selfMem: eventSelfMems[selectedEventIndex]
      )
  else:
    # All events.
    for i, event in trace.traceEvents:
      let eventEnd = event.ts + event.dur

      # Skip events that don't overlap with range.
      if rangeSelectionActive and (eventEnd <= rangeStart or event.ts >= rangeEnd):
        continue

      let clipped = clipEventToRange(event.ts, eventEnd)

      if clipped.duration > 0:
        if not statsMap.hasKey(event.name):
          statsMap[event.name] = EventStats(
            name: event.name,
            totalTime: 0.0,
            selfTime: 0.0,
            count: 0,
            totalAlloc: 0,
            totalDeloc: 0,
            totalMem: 0,
            selfMem: 0
          )
        statsMap[event.name].totalTime += clipped.duration
        statsMap[event.name].count += 1
        statsMap[event.name].totalAlloc += event.alloc
        statsMap[event.name].totalDeloc += event.deloc
        statsMap[event.name].totalMem += event.mem
        statsMap[event.name].selfMem += eventSelfMems[i]

  # Second pass: compute self time using interval coverage algorithm.
  if isSingleEvent:
    # Compute self time for just the selected event.
    let i = selectedEventIndex
    let event = trace.traceEvents[i]

    let eventStart = event.ts
    let eventEnd = event.ts + event.dur

    # Clip the event to the range.
    let clippedEvent = clipEventToRange(eventStart, eventEnd)
    if clippedEvent.duration == 0:
      return result

    # Collect all child event time ranges (events that start within this event's duration).
    # Clip children to both the parent bounds AND the range.
    var childRanges: seq[tuple[start: float, finish: float]]

    for j in (i+1)..<trace.traceEvents.len:
      let child = trace.traceEvents[j]

      # If child starts after parent ends, we're done.
      if child.ts >= eventEnd:
        break

      # If child starts within parent, add its range (clipped to parent bounds and range).
      if child.ts >= eventStart:
        let childStart = max(child.ts, clippedEvent.start)
        let childEnd = min(child.ts + child.dur, min(eventEnd, clippedEvent.finish))

        if childEnd > childStart:
          childRanges.add((start: childStart, finish: childEnd))

    # Merge overlapping child ranges to avoid double counting.
    var coveredTime = 0.0
    if childRanges.len > 0:
      # Sort by start time (should already be sorted, but let's be sure).
      childRanges.sort(proc(a, b: auto): int = cmp(a.start, b.start))

      var mergedStart = childRanges[0].start
      var mergedEnd = childRanges[0].finish

      for k in 1..<childRanges.len:
        if childRanges[k].start <= mergedEnd:
          # Overlapping or adjacent, extend the merged range.
          mergedEnd = max(mergedEnd, childRanges[k].finish)
        else:
          # Gap found, add the previous merged range to covered time.
          coveredTime += (mergedEnd - mergedStart)
          mergedStart = childRanges[k].start
          mergedEnd = childRanges[k].finish

      # Add the last merged range.
      coveredTime += (mergedEnd - mergedStart)

    let selfTime = clippedEvent.duration - coveredTime
    statsMap[event.name].selfTime = selfTime
  else:
    # Compute self time for all events.
    for i, event in trace.traceEvents:
      let eventStart = event.ts
      let eventEnd = event.ts + event.dur

      # Skip events that don't overlap with range.
      if rangeSelectionActive and (eventEnd <= rangeStart or eventStart >= rangeEnd):
        continue

      # Clip the event to the range.
      let clippedEvent = clipEventToRange(eventStart, eventEnd)
      if clippedEvent.duration == 0:
        continue

      # Collect all child event time ranges: events that start within this event's duration.
      # Clip children to both the parent bounds AND the range.
      var childRanges: seq[tuple[start: float, finish: float]]

      for j in (i+1)..<trace.traceEvents.len:
        let child = trace.traceEvents[j]

        # If child starts after parent ends, we are done.
        if child.ts >= eventEnd:
          break

        # If child starts within parent, add its range clipped to parent bounds and range.
        if child.ts >= eventStart:
          let childStart = max(child.ts, clippedEvent.start)
          let childEnd = min(child.ts + child.dur, min(eventEnd, clippedEvent.finish))

          if childEnd > childStart:
            childRanges.add((start: childStart, finish: childEnd))

      # Merge overlapping child ranges to avoid double counting.
      var coveredTime = 0.0
      if childRanges.len > 0:
        # Sort by start time (should already be sorted, but let's be sure).
        childRanges.sort(proc(a, b: auto): int = cmp(a.start, b.start))

        var mergedStart = childRanges[0].start
        var mergedEnd = childRanges[0].finish

        for k in 1..<childRanges.len:
          if childRanges[k].start <= mergedEnd:
            # Overlapping or adjacent, extend the merged range.
            mergedEnd = max(mergedEnd, childRanges[k].finish)
          else:
            # Gap found, add the previous merged range to covered time.
            coveredTime += (mergedEnd - mergedStart)
            mergedStart = childRanges[k].start
            mergedEnd = childRanges[k].finish

        # Add the last merged range.
        coveredTime += (mergedEnd - mergedStart)

      let selfTime = clippedEvent.duration - coveredTime
      statsMap[event.name].selfTime += selfTime

  # Convert to sorted sequence (by total time, descending).
  result = @[]
  for stats in statsMap.values:
    result.add(stats)
  result.sort(proc(a, b: EventStats): int = cmp(b.totalTime, a.totalTime))

proc drawTraceTable(panel: Panel, frameId: string, contentPos: Vec2, contentSize: Vec2) =
  ## Draw the trace statistics table panel with sortable columns.
  frame(frameId, contentPos, contentSize):
    # Check if range has changed.
    let currentRange = (
      active: rangeSelectionActive,
      start: min(rangeSelectionStart, rangeSelectionEnd),
      finish: max(rangeSelectionStart, rangeSelectionEnd)
    )
    let rangeChanged = (
      currentRange.active != lastRangeForStats.active or
      currentRange.start != lastRangeForStats.start or
      currentRange.finish != lastRangeForStats.finish
    )

    # Recompute stats if selection changed, range changed, or not computed yet.
    if not traceStatsComputed or lastSelectedEventIndex != selectedEventIndex or rangeChanged:
      cachedTraceStats = computeTraceStats()
      traceStatsComputed = true
      lastSelectedEventIndex = selectedEventIndex
      lastRangeForStats = currentRange

    # Apply sorting to the stats.
    if tableSortColumn != "":
      cachedTraceStats.sort(proc(a, b: EventStats): int =
        var cmpResult = 0
        case tableSortColumn:
        of "name":
          cmpResult = cmp(a.name, b.name)
        of "count":
          cmpResult = cmp(a.count, b.count)
        of "total":
          cmpResult = cmp(a.totalTime, b.totalTime)
        of "self":
          cmpResult = cmp(a.selfTime, b.selfTime)
        of "alloc":
          cmpResult = cmp(a.totalAlloc, b.totalAlloc)
        of "deloc":
          cmpResult = cmp(a.totalDeloc, b.totalDeloc)
        of "mem":
          cmpResult = cmp(a.totalMem, b.totalMem)
        of "selfMem":
          cmpResult = cmp(a.selfMem, b.selfMem)
        else:
          cmpResult = 0

        if tableSortAscending:
          return cmpResult
        else:
          return -cmpResult
      )

    # Draw table header.
    sk.at = contentPos + vec2(10, 10)
    let headerY = sk.at.y
    let nameColX = sk.at.x
    let countColX = sk.at.x + 200
    let totalColX = sk.at.x + 260
    let selfColX = sk.at.x + 370
    let allocColX = sk.at.x + 480
    let delocColX = sk.at.x + 550
    let memColX = sk.at.x + 620
    let selfMemColX = sk.at.x + 720

    # Helper to draw header with click detection.
    let mousePos = window.mousePos.vec2
    let headerHeight = 20.0

    proc drawHeaderColumn(label: string, colX: float, colWidth: float, columnId: string) =
      let headerRect = rect(colX, headerY, colWidth, headerHeight)
      let isHovered = mousePos.overlaps(headerRect)

      # Detect clicks on header.
      if isHovered and window.buttonPressed[MouseLeft]:
        if tableSortColumn == columnId:
          # Already sorting by this column, toggle direction or clear.
          if tableSortAscending:
            tableSortAscending = false
          else:
            # Clear sorting.
            tableSortColumn = ""
        else:
          # Start sorting by this column (ascending).
          tableSortColumn = columnId
          tableSortAscending = true

      # Draw header text.
      var displayLabel = label
      if tableSortColumn == columnId:
        displayLabel &= (if tableSortAscending: " ac" else: " dc")

      let textColor = if isHovered: rgbx(255, 255, 255, 255) else: rgbx(200, 200, 200, 255)
      discard sk.drawText("Default", displayLabel, vec2(colX, headerY), textColor)

    # Draw headers.
    drawHeaderColumn("Event Name", nameColX, 190.0, "name")
    drawHeaderColumn("Count", countColX, 50.0, "count")
    drawHeaderColumn("Total (ms)", totalColX, 100.0, "total")
    drawHeaderColumn("Self (ms)", selfColX, 100.0, "self")
    drawHeaderColumn("Allocs", allocColX, 60.0, "alloc")
    drawHeaderColumn("Delocs", delocColX, 60.0, "deloc")
    drawHeaderColumn("Mem", memColX, 90.0, "mem")
    drawHeaderColumn("Self Mem", selfMemColX, 100.0, "selfMem")

    # Draw separator line.
    let lineY = headerY + 25
    sk.drawRect(vec2(nameColX, lineY), vec2(contentSize.x - 20, 1), rgbx(100, 100, 100, 255))

    # Draw rows.
    var rowY = lineY + 10
    let maxRows = ((contentSize.y - (rowY - contentPos.y) - 10) / 25).int

    for i in 0..<min(cachedTraceStats.len, maxRows):
      let stats = cachedTraceStats[i]
      let color = nameToColor(stats.name)

      # Draw color indicator.
      sk.drawRect(vec2(nameColX - 5, rowY + 2), vec2(3, 16), color)

      # Draw stats.
      discard sk.drawText("Default", stats.name, vec2(nameColX, rowY), rgbx(255, 255, 255, 255), maxWidth = 190)
      discard sk.drawText("Default", $stats.count, vec2(countColX, rowY), rgbx(255, 255, 255, 255))
      discard sk.drawText("Default", &"{stats.totalTime / 1000:.4f}", vec2(totalColX, rowY), rgbx(255, 255, 255, 255))
      discard sk.drawText("Default", &"{stats.selfTime / 1000:.4f}", vec2(selfColX, rowY), rgbx(255, 255, 255, 255))
      discard sk.drawText("Default", $stats.totalAlloc, vec2(allocColX, rowY), rgbx(255, 255, 255, 255))
      discard sk.drawText("Default", $stats.totalDeloc, vec2(delocColX, rowY), rgbx(255, 255, 255, 255))
      discard sk.drawText("Default", formatBytes(stats.totalMem), vec2(memColX, rowY), rgbx(255, 255, 255, 255))
      discard sk.drawText("Default", formatBytes(stats.selfMem), vec2(selfMemColX, rowY), rgbx(255, 255, 255, 255))

      rowY += 25

proc drawAllocNumbers(panel: Panel, frameId: string, contentPos: Vec2, contentSize: Vec2) =
  ## Draw the allocation count panel placeholder.
  frame(frameId, contentPos, contentSize):
    h1text("Alloc Numbers")
    text("This is the alloc numbers")

proc drawAllocSize(panel: Panel, frameId: string, contentPos: Vec2, contentSize: Vec2) =
  ## Draw the allocation size panel placeholder.
  frame(frameId, contentPos, contentSize):
    h1text("Alloc Size")
    text("This is the alloc size")

proc worstAspect(areas: seq[float], w: float): float =
  ## Compute worst aspect ratio for a row in squarified treemap.
  if areas.len == 0 or w <= 0: return 1e18
  var s, rmax: float
  var rmin = 1e18
  for a in areas:
    s += a
    rmax = max(rmax, a)
    rmin = min(rmin, a)
  if s <= 0 or rmin <= 0: return 1e18
  let s2 = s * s
  let w2 = w * w
  return max(w2 * rmax / s2, s2 / (w2 * rmin))

proc layoutSquarified(values: seq[float], bounds: Rect): seq[Rect] =
  ## Layout rectangles using squarified treemap algorithm.
  result = newSeq[Rect](values.len)
  if values.len == 0: return
  var totalValue = 0.0
  for v in values: totalValue += v
  if totalValue <= 0 or bounds.w <= 0 or bounds.h <= 0: return
  let totalArea = bounds.w * bounds.h
  var areas = newSeq[float](values.len)
  for i, v in values:
    areas[i] = v / totalValue * totalArea
  var remaining = bounds
  var idx = 0
  while idx < areas.len:
    let w = min(remaining.w, remaining.h)
    if w <= 0: break
    var row = @[areas[idx]]
    var rowCount = 1
    while idx + rowCount < areas.len:
      var newRow = row
      newRow.add(areas[idx + rowCount])
      if worstAspect(newRow, w) <= worstAspect(row, w):
        row = newRow
        inc rowCount
      else:
        break
    var rowSum = 0.0
    for a in row: rowSum += a
    if remaining.w >= remaining.h:
      let stripW = if remaining.h > 0: rowSum / remaining.h else: remaining.w
      var y = remaining.y
      for i in 0..<rowCount:
        let h = if stripW > 0: row[i] / stripW else: 0.0
        result[idx + i] = rect(remaining.x, y, stripW, h)
        y += h
      remaining = rect(remaining.x + stripW, remaining.y, remaining.w - stripW, remaining.h)
    else:
      let stripH = if remaining.w > 0: rowSum / remaining.w else: remaining.h
      var x = remaining.x
      for i in 0..<rowCount:
        let itemW = if stripH > 0: row[i] / stripH else: 0.0
        result[idx + i] = rect(x, remaining.y, itemW, stripH)
        x += itemW
      remaining = rect(remaining.x, remaining.y + stripH, remaining.w, remaining.h - stripH)
    idx += rowCount

proc computeTreemap() =
  ## Compute treemap layout data from the current range selection.
  treemapGroups.setLen(0)
  if trace == nil or trace.traceEvents.len == 0: return
  let rangeActive = rangeSelectionActive
  let rStart = if rangeActive: min(rangeSelectionStart, rangeSelectionEnd) else: 0.0
  let rEnd = if rangeActive: max(rangeSelectionStart, rangeSelectionEnd) else: 0.0
  var groupMap: Table[string, int]
  for i, event in trace.traceEvents:
    let selfMem = eventSelfMems[i]
    if selfMem <= 0: continue
    if rangeActive:
      let eventEnd = event.ts + event.dur
      if eventEnd <= rStart or event.ts >= rEnd: continue
    if event.name notin groupMap:
      groupMap[event.name] = treemapGroups.len
      treemapGroups.add(TreemapGroup(name: event.name))
    let gi = groupMap[event.name]
    treemapGroups[gi].items.add(TreemapItem(
      eventIndex: i, name: event.name, value: selfMem.float
    ))
    treemapGroups[gi].totalValue += selfMem.float
  treemapGroups.sort(proc(a, b: TreemapGroup): int = cmp(b.totalValue, a.totalValue))

proc drawMemoryTreemap(panel: Panel, frameId: string, contentPos: Vec2, contentSize: Vec2) =
  ## Draw a treemap visualization of memory allocations.
  frame(frameId, contentPos, contentSize):
    let mousePos = window.mousePos.vec2
    let contentRect = rect(contentPos.x, contentPos.y, contentSize.x, contentSize.y)
    let isMouseOver = mousePos.overlaps(contentRect)
    # Recompute treemap data when range selection changes.
    let currentRange = (
      active: rangeSelectionActive,
      start: min(rangeSelectionStart, rangeSelectionEnd),
      finish: max(rangeSelectionStart, rangeSelectionEnd)
    )
    if treemapNeedsUpdate or currentRange != treemapLastRange:
      computeTreemap()
      treemapLastRange = currentRange
      treemapNeedsUpdate = false
    if treemapGroups.len == 0:
      discard sk.drawText(
        "Default",
        "No memory allocations in selection.",
        contentPos + vec2(10, 10),
        rgbx(150, 150, 150, 255)
      )
      return
    # Compute group-level layout.
    let margin = 2.0
    let bounds = rect(
      contentPos.x + margin,
      contentPos.y + margin,
      contentSize.x - margin * 2,
      contentSize.y - margin * 2
    )
    var groupValues = newSeq[float](treemapGroups.len)
    for i in 0..<treemapGroups.len:
      groupValues[i] = treemapGroups[i].totalValue
    let groupRects = layoutSquarified(groupValues, bounds)
    var hoveredEvent = -1
    var hoveredRect: Rect
    # Draw each group and its items.
    for gi in 0..<treemapGroups.len:
      let gRect = groupRects[gi]
      if gRect.w < 1 or gRect.h < 1: continue
      let color = nameToColor(treemapGroups[gi].name)
      let borderColor = rgbx(
        min(255, color.r.int + 20).uint8,
        min(255, color.g.int + 20).uint8,
        min(255, color.b.int + 20).uint8,
        255
      )
      # Compute item-level layout within the group.
      let innerRect = rect(
        gRect.x + 1, gRect.y + 1,
        max(1, gRect.w - 2), max(1, gRect.h - 2)
      )
      var itemValues = newSeq[float](treemapGroups[gi].items.len)
      for i in 0..<treemapGroups[gi].items.len:
        itemValues[i] = treemapGroups[gi].items[i].value
      let itemRects = layoutSquarified(itemValues, innerRect)
      # Draw item rectangles.
      for i in 0..<treemapGroups[gi].items.len:
        let r = itemRects[i].snapToPixels()
        if r.w < 1 or r.h < 1: continue
        # Highlight selected event in gray like the timeline.
        let isSelected = treemapGroups[gi].items[i].eventIndex == selectedEventIndex
        let drawColor = if isSelected: rgbx(200, 200, 200, 255) else: color
        sk.drawRect(r.xy, r.wh, drawColor)
        if r.w > 2 and r.h > 2:
          sk.drawRect(r.xy, vec2(r.w, 1), borderColor)
          sk.drawRect(r.xy, vec2(1, r.h), borderColor)
        # Track hover.
        if isMouseOver and mousePos.overlaps(r):
          hoveredEvent = treemapGroups[gi].items[i].eventIndex
          hoveredRect = r
      # Draw group outline.
      let gr = gRect.snapToPixels()
      sk.drawRect(gr.xy, vec2(gr.w, 1), rgbx(0, 0, 0, 255))
      sk.drawRect(gr.xy, vec2(1, gr.h), rgbx(0, 0, 0, 255))
      sk.drawRect(vec2(gr.x + gr.w - 1, gr.y), vec2(1, gr.h), rgbx(0, 0, 0, 255))
      sk.drawRect(vec2(gr.x, gr.y + gr.h - 1), vec2(gr.w, 1), rgbx(0, 0, 0, 255))
      # Draw group label.
      if gRect.w > 50 and gRect.h > 18:
        let label = treemapGroups[gi].name & " " &
          formatBytes(treemapGroups[gi].totalValue.int)
        discard sk.drawText(
          "Default",
          label,
          vec2(gRect.x + 4, gRect.y + 2),
          rgbx(255, 255, 255, 255),
          maxWidth = gRect.w - 8
        )
    # Draw hover highlight on top.
    if hoveredEvent >= 0:
      sk.drawRect(hoveredRect.xy, hoveredRect.wh, rgbx(128, 128, 128, 128))
    # Handle click to select event on timeline.
    if isMouseOver and window.buttonPressed[MouseLeft] and dragPanel == nil:
      if hoveredEvent >= 0:
        selectedEventIndex = hoveredEvent
        traceStatsComputed = false
    # Draw tooltip for hovered item.
    if hoveredEvent >= 0 and hoveredEvent < trace.traceEvents.len:
      let event = trace.traceEvents[hoveredEvent]
      let selfMem = eventSelfMems[hoveredEvent]
      let tip = event.name & ": " & formatBytes(selfMem) &
        " self (" & formatBytes(event.mem) & " total, " & $event.alloc & " allocs)"
      let tipSize = sk.getTextSize("Default", tip)
      let tipPos = mousePos + vec2(12, 12)
      sk.draw9Patch(
        "tooltip.9patch", 4,
        tipPos - vec2(4, 2),
        vec2(tipSize.x + 8, tipSize.y + 4),
        rgbx(0, 0, 0, 220)
      )
      discard sk.drawText("Default", tip, tipPos, rgbx(255, 255, 255, 255))

proc loadTraceFile(filePath: string) =
  ## Load a trace file and reset related state.
  try:
    echo "Loading trace file: ", filePath
    trace = readFile(filePath).fromJson(Trace)
    trace.traceEvents.sort(proc(a: TraceEvent, b: TraceEvent): int =
      return cmp(a.ts, b.ts))

    # Compute self memory for each event.
    computeEventSelfMems()

    # Reset trace stats cache.
    traceStatsComputed = false
    cachedTraceStats.setLen(0)

    # Reset treemap cache.
    treemapGroups.setLen(0)
    treemapLastRange = (active: false, start: 0.0, finish: 0.0)
    treemapNeedsUpdate = true

    # Reset selection.
    selectedEventIndex = -1

    # Reset range selection.
    rangeSelectionActive = false
    rangeSelectionDragging = false

    # Reset zoom and pan.
    timelineZoom = 1.0
    timelinePanOffset = 0.0
    timelinePanning = false

    echo "Trace loaded successfully: ", trace.traceEvents.len, " events"
  except Exception as e:
    echo "Error loading trace file: ", e.msg

proc initRootArea() =
  ## Initialize the root area with default panel layout.
  randomize()
  rootArea = Area()
  rootArea.split(Horizontal)
  rootArea.split = 0.70

  rootArea.areas[0].addPanel("Trace Timeline", drawTraceTimeline)
  rootArea.areas[1].split(Vertical)
  rootArea.areas[1].split = 0.5
  rootArea.areas[1].areas[0].addPanel("Trace Table", drawTraceTable)
  rootArea.areas[1].areas[1].addPanel("Memory", drawMemoryTreemap)

window.onFrame = proc() =
  # Check for reload keys (F5 or Ctrl+R).
  if window.buttonPressed[KeyF5] or (window.buttonDown[KeyLeftControl] and window.buttonPressed[KeyR]):
    loadTraceFile(traceFilePath)

  sk.beginUI(window, window.size)

  # Background.
  sk.drawRect(vec2(0, 0), window.size.vec2, BackgroundColor)

  # Reset cursor.
  sk.cursor = Cursor(kind: ArrowCursor)

  drawPanels()

  # let ms = sk.avgFrameTime * 1000
  # sk.at = sk.pos + vec2(sk.size.x - 600, 2)
  # let mem = getOccupiedMem()
  # let memoryChange = mem - prevMem
  # prevMem = mem
  # let memCounters0 = getMemCounters()
  # type MemCounters = object
  #   allocCounter: int
  #   deallocCounter: int
  # let memCounters = cast[MemCounters](memCounters0)
  # let numAlloc = memCounters.allocCounter
  # let numAllocChange = numAlloc - prevNumAlloc
  # prevNumAlloc = numAlloc

  # text(&"frame time: {ms:>7.3}ms {sk.instanceCount} {memoryChange}bytes/frame {numAllocChange}allocs/frame")

  sk.endUi()
  window.swapBuffers()

  if window.cursor.kind != sk.cursor.kind:
    window.cursor = sk.cursor

# Parse command line arguments.
if paramCount() > 0:
  traceFilePath = paramStr(1)
  echo "Using trace file from command line: ", traceFilePath
else:
  echo "Using default trace file: ", traceFilePath

initRootArea()
loadTraceFile(traceFilePath)

while not window.closeRequested:
  pollEvents()
