import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'globals.dart';

// Everything one transfer has to say. The row on the main screen carries the
// outcome — "received 2 of 3" and a single error line — and that is as far as it
// can go; which file failed, and why, lives here. The log is kept in memory by
// the session itself, so it goes away with the transfer at restart.
class TransferLogScreen extends StatelessWidget {
  final TransferSession transfer;

  const TransferLogScreen(this.transfer, {super.key});

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: transferLogText(transfer)));
    okInfoBarGreen(lw('Copied'));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: clFon,
      appBar: AppBar(
        title: Text(
          lw('Transfer log'),
          style: const TextStyle(fontSize: fsLarge),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy),
            tooltip: lw('Copy'),
            onPressed: _copy,
          ),
        ],
      ),
      // A running transfer writes while the screen is open, so it follows the
      // same tick the main screen does.
      body: ValueListenableBuilder<int>(
        valueListenable: transfersTick,
        builder: (context, _, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [_header(), Expanded(child: _lines())],
        ),
      ),
    );
  }

  Widget _header() {
    final List<String> lines = transferLogHeader(transfer);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            transfer.incoming ? Icons.download : Icons.upload,
            size: 18,
            color: clText,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(lines.first, style: tsNormal),
                // The error, when there is one, is the last line the header
                // produces, and the only one that has to be read in red.
                for (int i = 1; i < lines.length; i++)
                  Text(
                    lines[i],
                    style: tsSmall.copyWith(
                      color: transfer.error != null && i == lines.length - 1
                          ? clError
                          : null,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _lines() {
    if (transfer.events.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Text(lw('Nothing to show yet'), style: tsNormal),
      );
    }
    // Oldest first, the order the events happened in and the order they are
    // copied in: a log read from both ends would be two different logs.
    return ListView.builder(
      itemCount: transfer.events.length,
      itemBuilder: (context, index) {
        final TransferEvent event = transfer.events[index];
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 2),
          child: Text(
            formatTransferEvent(event),
            // Body size, not the small print: this is the text that gets read
            // line by line to find the one file that did not make it.
            style: tsNormal.copyWith(color: event.failure ? clError : clText),
          ),
        );
      },
    );
  }
}
