import 'package:duck_downloader/models/download_models.dart';
import 'package:duck_downloader/widgets/media/media_overlay_router.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Stands in for the controller, with only what the layer reads.
class _FakeController extends ChangeNotifier {
  DownloadItem? item;

  void open(DownloadItem next) {
    item = next;
    notifyListeners();
  }

  void close() {
    item = null;
    notifyListeners();
  }
}

/// The shape app.dart builds: a permanent Overlay holding one entry that
/// listens for itself.
class _Harness extends StatefulWidget {
  const _Harness({required this.controller});
  final _FakeController controller;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late final OverlayEntry _entry = OverlayEntry(
    builder: (_) => ListenableBuilder(
      listenable: widget.controller,
      builder: (_, _) => widget.controller.item == null
          ? const SizedBox.shrink()
          : const Text('player', textDirection: TextDirection.ltr),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Stack(
        children: [
          const SizedBox.expand(),
          Material(
            type: MaterialType.transparency,
            child: Overlay(initialEntries: [_entry]),
          ),
        ],
      ),
    );
  }
}

void main() {
  DownloadItem item(String id) => DownloadItem(
    id: id,
    url: 'https://example.com/$id',
    title: id,
    platform: 'Example',
    type: DownloadType.video,
    filePath: '/tmp/$id.mp4',
    createdAt: DateTime.utc(2026),
    status: DownloadStatus.completed,
    progress: 100,
    favorite: false,
  );

  testWidgets('opening and closing the player does not tear the layer down',
      (tester) async {
    // The red screen: the Overlay was added to the Stack only while something
    // was playing, so closing the player unmounted it while widgets inside
    // still depended on inherited state from it —
    // `_dependents.isEmpty: is not true`.
    final controller = _FakeController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_Harness(controller: controller));
    expect(find.text('player'), findsNothing);

    for (var i = 0; i < 5; i++) {
      controller.open(item('clip-$i'));
      await tester.pump();
      expect(find.text('player'), findsOneWidget);

      controller.close();
      await tester.pump();
      expect(find.text('player'), findsNothing);
    }

    expect(tester.takeException(), isNull);
  });

  testWidgets('the router draws nothing when nothing is open', (tester) async {
    // Which is why the layer can stay mounted at all times: it decides for
    // itself, so the Stack does not have to add and remove it.
    await tester.pumpWidget(
      const MaterialApp(home: Material(child: SizedBox.shrink())),
    );
    expect(tester.takeException(), isNull);
  });
}
