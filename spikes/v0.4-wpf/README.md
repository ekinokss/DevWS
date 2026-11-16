# DevWS v0.4 WPF Feasibility Spike

**Experimental — not the DevWS editor.**

This standalone WPF application is a P2 feasibility spike. It demonstrates a monitor canvas
in DevWS virtual-screen coordinates using synthetic JSON fixtures and an optional
host-derived topology snapshot.

It does **not**:

- implement the P1 JSON Lines backend;
- read or write the DevWS canonical configuration;
- launch, move, close, focus, or reset managed windows;
- register hotkeys or scheduled tasks;
- modify display settings;
- integrate into the shipping installer or application.

## Build

Requires the .NET 8 SDK and the Windows Desktop runtime.

```powershell
dotnet build .\spikes\v0.4-wpf\DevWS.WpfSpike.csproj -c Release
```

## Run

```powershell
dotnet run --project .\spikes\v0.4-wpf\DevWS.WpfSpike.csproj -c Release
```

The app starts with `Fixtures/two-monitors-10-items.json`. Use the fixture selector to load
the 4-monitor/50-item or 8-monitor/200-item fixtures. The host-derived
`host-topology.json` contains real monitor rectangles/work areas with redacted names and
identities.

## Controls

- **Mouse wheel**: zoom at the pointer.
- **Middle or right drag**: pan.
- **Left click**: select an item, then a monitor.
- **Arrow keys**: nudge the selected item by 1 px; **Shift+Arrow** by 10 px.
- **+ / −**: zoom; **F**: fit; **Escape**: clear selection.
- **Monitor list / item list**: keyboard selection; the numeric fields are the non-mouse
  editor.
- **Apply geometry**: commit numeric X/Y/W/H to the in-memory fixture only.

The canvas shows monitor rectangles (solid), work areas (dashed), and configured item
rectangles. The status bar reports the pointer position in DevWS virtual-screen coordinates.

## Geometry contract

The canvas uses:

```text
screen = (world - virtualScreenOrigin) * zoom + pan
world  = (screen - pan) / zoom + virtualScreenOrigin
```

`world` is the DevWS backend virtual-screen coordinate space. WPF device-independent pixels
are only the drawing surface; the transform does not use WPF DPI for geometry.

## Fixtures and tools

| Path | Purpose |
| --- | --- |
| `Fixtures/two-monitors-10-items.json` | Negative origin, non-primary left monitor, synthetic 150% right monitor |
| `Fixtures/four-monitors-50-items.json` | 2×2 arrangement with negative X/Y origins |
| `Fixtures/eight-monitors-200-items.json` | 8 monitors, 200 items |
| `Fixtures/host-topology.json` | Read-only snapshot from `Get-DevWSMonitorTopology`, names/identities redacted |
| `tools/New-SyntheticFixtures.ps1` | Regenerates the synthetic fixtures |
| `tools/Export-DevWSTopology.ps1` | Read-only host topology export; does not read workspace config |
| `tools/Measure-Startup.ps1` | Repeated startup/interaction measurements |
| `tools/Measure-Publish.ps1` | Framework-dependent/self-contained/single-file publish measurements |

## Self-test

The geometry self-test runs without opening a window:

```powershell
dotnet run --project .\spikes\v0.4-wpf\DevWS.WpfSpike.csproj -c Release -- --self-test --log .\spikes\v0.4-wpf\results\self-test.json
```

## Benchmark modes

```powershell
dotnet run --project .\spikes\v0.4-wpf\DevWS.WpfSpike.csproj -c Release -- `
  --benchmark --fixture .\spikes\v0.4-wpf\Fixtures\two-monitors-10-items.json `
  --exit-after-ms 1500 --log .\spikes\v0.4-wpf\results\startup-2m-10i.json
```

`--interaction-benchmark --frames 120` additionally runs a transform/layout loop and records
working-set/CPU deltas. The interaction metric is a transform/layout cost, not a GPU
rendering benchmark.

## Accessibility

The custom canvas exposes a single named UI Automation pane. The monitor and item lists plus
the numeric geometry fields provide the keyboard/text alternative. The production editor's
accessibility design remains a later task.

## Limitations

- No mixed-DPI physical test was executed on the P2 host (both monitors are 100%).
- No negative-origin physical monitor was available; negative origins are synthetic.
- The interaction benchmark does not measure GPU frame rate.
- The prototype does not implement the P1 backend or save configuration.
