import 'package:flutter/material.dart';
import 'package:turbosheet/src/rust/api/simple.dart';
import 'package:turbosheet/src/rust/frb_generated.dart';


Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF1E1E1E),
      ),
      home: const SpreadsheetLoader(),
    );
  }
}

class SpreadsheetLoader extends StatefulWidget {
  const SpreadsheetLoader({super.key});

  @override
  State<SpreadsheetLoader> createState() => _SpreadsheetLoaderState();
}

class _SpreadsheetLoaderState extends State<SpreadsheetLoader> {
  late Future<SheetSession> _sessionFuture;

  @override
  void initState() {
    super.initState();
    // NEW: No Future.value() wrapper needed. newDemo is now async native.
    _sessionFuture = SheetSession.newDemo(rows: 1000000000, cols: 1000000000);
  }
  @override
  Widget build(BuildContext context) {
    return FutureBuilder<SheetSession>(
      future: _sessionFuture,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return TurboViewer(session: snapshot.data!);
        } else if (snapshot.hasError) {
          return Scaffold(body: Center(child: Text("Error: ${snapshot.error}")));
        }
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      },
    );
  }
}

class TurboViewer extends StatefulWidget {
  final SheetSession session;
  const TurboViewer({super.key, required this.session});

  @override
  State<TurboViewer> createState() => _TurboViewerState();
}

class _TurboViewerState extends State<TurboViewer> {
  // State for data
  final Map<int, RowData> _rowCache = {};
  final Set<int> _loadingPages = {};
  
  // Configuration
  final int _rowsPerPage = 60;
  final int _visibleCols = 6; // How many cols to show on screen at once
  
  // Navigation State
  int _currentColStart = 0;
  
  // Controllers
  final ScrollController _verticalController = ScrollController();
  final TextEditingController _jumpController = TextEditingController();

  // Dynamic Headers
  List<String> _currentHeaders = [];

  @override
  @override
  void initState() {
    super.initState();
    // Fire the request. The UI will update when data arrives.
    _refreshHeaders();
  }

  // NEW: Marked as async
  // NEW: Marked as async so we can await the Rust result
  Future<void> _refreshHeaders() async {
    // 1. Capture current horizontal position to prevent race conditions
    // (If the user scrolls fast, we only want the latest result)
    final requestedColStart = _currentColStart;
    
    // 2. Await the Rust result
    // This used to be synchronous, now it's a Future!
    final newHeaders = await widget.session.getHeaderChunk(
      colStart: _currentColStart, 
      colCount: _visibleCols
    );

    // 3. Safety Check: If the widget was closed or the user scrolled away 
    // while we were waiting, discard this old data.
    if (!mounted || _currentColStart != requestedColStart) return;

    setState(() {
      _currentHeaders = newHeaders;
    });

    // Invalidate row cache because columns have changed
    _rowCache.clear(); 
    _loadingPages.clear();
  }
  void _fetchPageIfNeeded(int rowIndex) {
    final int pageIndex = rowIndex ~/ _rowsPerPage;
    if (_loadingPages.contains(pageIndex)) return;
    
    _loadingPages.add(pageIndex);
    final int startRow = pageIndex * _rowsPerPage;

    Future.microtask(() async {
      try {
        // Ask Rust for a 2D Chunk
        final newRows = await widget.session.getGridChunk(
          rowStart: startRow, 
          rowCount: _rowsPerPage,
          colStart: _currentColStart, // Current Horizontal Position
          colCount: _visibleCols
        );

        if (mounted) {
          setState(() {
            for (var row in newRows) {
              _rowCache[row.index.toInt()] = row;
            }
            _loadingPages.remove(pageIndex);
          });
        }
      } catch (e) {
        if (mounted) _loadingPages.remove(pageIndex);
      }
    });
  }
void _scrollHorizontal(int delta) {
    int newStart = _currentColStart + delta;

    // FIX: Calculate strict maximum limit
    int maxStart = (widget.session.totalCols - _visibleCols).toInt();

    // FIX: Clamp safely between 0 and maxStart
    if (newStart < 0) newStart = 0;
    if (newStart > maxStart) newStart = maxStart;

    if (newStart != _currentColStart) {
      _currentColStart = newStart;
      _refreshHeaders();
    }
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text("Grid: ${widget.session.totalRows}R x ${widget.session.totalCols}C"),
        actions: [
           // Quick Navigation for Columns
           IconButton(
            icon: const Icon(Icons.arrow_back_ios),
            onPressed: () => _scrollHorizontal(-1),
            tooltip: "Prev Col",
          ),
          Center(child: Text(" Col $_currentColStart ")),
          IconButton(
            icon: const Icon(Icons.arrow_forward_ios),
            onPressed: () => _scrollHorizontal(1),
            tooltip: "Next Col",
          ),
          const SizedBox(width: 10),
          IconButton(onPressed: _showJumpDialog, icon: const Icon(Icons.rocket_launch)),
        ],
      ),
      body: Column(
        children: [
          _buildHeaderRow(),
          Expanded(
            child: ListView.builder(
              controller: _verticalController,
              itemCount: widget.session.totalRows.toInt(),
              itemExtent: 40.0,
              itemBuilder: (context, index) {
                if (_rowCache.containsKey(index)) {
                  return _buildDataRow(_rowCache[index]!, index);
                } else {
                  _fetchPageIfNeeded(index);
                  return _buildLoadingRow(index);
                }
              },
            ),
          ),
          // Horizontal Scrollbar simulation
          _buildHorizontalControl(),
        ],
      ),
    );
  }

  Widget _buildHorizontalControl() {
    return Container(
      color: Colors.black45,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          const Text("Horizontal Pos: "),
          Expanded(
            child: Slider(
              // FIX: Clamp the value to ensure it never exceeds max, preventing the crash
              value: _currentColStart.toDouble().clamp(
                0.0,
                (widget.session.totalCols - _visibleCols).toDouble(),
              ),
              min: 0,
              // FIX: Ensure max matches the logic in _scrollHorizontal
              max: (widget.session.totalCols - _visibleCols).toDouble(),
              onChanged: (val) {
                // Debouncing should be added here for production
                if ((val - _currentColStart).abs() > 5) {
                   setState(() {
                    _currentColStart = val.toInt();
                    _refreshHeaders();
                  });
                }
              },
            ),
          ),
          Text("$_currentColStart"),
        ],
      ),
    );
  }

  Widget _buildHeaderRow() {
    return Container(
      height: 40,
      color: Colors.grey[850],
      child: Row(
        children: [
          const SizedBox(
            width: 60, 
            child: Center(child: Text("#", style: TextStyle(fontWeight: FontWeight.bold)))
          ),
          ..._currentHeaders.map((h) => Expanded(
            child: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: Colors.grey[700]!))),
              child: Text(h, style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildDataRow(RowData row, int index) {
    return Container(
      color: index % 2 == 0 ? Colors.white.withOpacity(0.05) : Colors.transparent,
      height: 40,
      child: Row(
        children: [
          SizedBox(
            width: 60,
            child: Center(child: Text("${row.index}", style: const TextStyle(color: Colors.grey, fontSize: 10)))
          ),
          ...row.cells.map((cell) => Expanded(
            child: Container(
              alignment: Alignment.centerLeft,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(border: Border(left: BorderSide(color: Colors.white10))),
              child: Text(cell.content, overflow: TextOverflow.ellipsis),
            ),
          )),
        ],
      ),
    );
  }

  Widget _buildLoadingRow(int index) {
    return Container(
      height: 40,
      alignment: Alignment.center,
      child: Text("Loading Row $index...", style: const TextStyle(fontSize: 10, color: Colors.white24)),
    );
  }
void _showJumpDialog() {
  TextEditingController rowController = TextEditingController();
  TextEditingController colController = TextEditingController();

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text("Jump to Coords"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: rowController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: "Row Index"),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: colController,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(labelText: "Column Index"),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () {
            final int? rIndex = int.tryParse(rowController.text);
            final int? cIndex = int.tryParse(colController.text);
            
            if (rIndex != null) {
              _verticalController.jumpTo(rIndex * 40.0);
            }
            if (cIndex != null) {
              // FIX: Clamp manual input so users can't type "1000000000" and crash it
              int maxStart = (widget.session.totalCols - _visibleCols).toInt();
              int safeCol = cIndex;
              
              if (safeCol > maxStart) safeCol = maxStart;
              if (safeCol < 0) safeCol = 0;

              setState(() {
                _currentColStart = safeCol;
                _refreshHeaders();
              });
            }
            
            Navigator.pop(context);
          },
          child: const Text("Go"),
        ),
      ],
    ),
  );
}
  
}
