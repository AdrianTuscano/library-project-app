import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class ResultsScreen extends StatelessWidget {
  final RecognizedText recognizedText;

  const ResultsScreen({super.key, required this.recognizedText});

  @override
  Widget build(BuildContext context) {
    final blocks = recognizedText.blocks;

    return Scaffold(
      appBar: AppBar(
        title: const Text('OCR Results'),
        backgroundColor: Colors.black87,
      ),
      backgroundColor: Colors.grey[900],
      body: blocks.isEmpty
          ? const Center(
              child: Text(
                'No text detected.',
                style: TextStyle(color: Colors.white70, fontSize: 16),
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: blocks.length,
              separatorBuilder: (_, __) => const Divider(color: Colors.white24),
              itemBuilder: (context, i) {
                final block = blocks[i];
                final r = block.boundingBox;
                return _BlockTile(
                  index: i,
                  text: block.text,
                  x: r.left,
                  y: r.top,
                  width: r.width,
                  height: r.height,
                  lines: block.lines,
                );
              },
            ),
    );
  }
}

class _BlockTile extends StatelessWidget {
  final int index;
  final String text;
  final double x, y, width, height;
  final List<TextLine> lines;

  const _BlockTile({
    required this.index,
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    required this.lines,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Block header: index + bounding box.
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.teal,
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'Block ${index + 1}',
                style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              'x:${x.toStringAsFixed(0)}  y:${y.toStringAsFixed(0)}  '
              'w:${width.toStringAsFixed(0)}  h:${height.toStringAsFixed(0)}',
              style: const TextStyle(color: Colors.white38, fontSize: 11, fontFamily: 'monospace'),
            ),
          ],
        ),
        const SizedBox(height: 6),
        // Full block text.
        Text(
          text,
          style: const TextStyle(color: Colors.white, fontSize: 15),
        ),
        // Per-line detail.
        if (lines.length > 1) ...[
          const SizedBox(height: 6),
          ...lines.map((line) {
            final lr = line.boundingBox;
            return Padding(
              padding: const EdgeInsets.only(left: 12, top: 2),
              child: Row(
                children: [
                  const Text('↳ ', style: TextStyle(color: Colors.tealAccent)),
                  Expanded(
                    child: Text(
                      '"${line.text}"  '
                      'x:${lr.left.toStringAsFixed(0)}  y:${lr.top.toStringAsFixed(0)}',
                      style: const TextStyle(color: Colors.white60, fontSize: 12, fontFamily: 'monospace'),
                    ),
                  ),
                ],
              ),
            );
          }),
        ],
      ],
    );
  }
}
