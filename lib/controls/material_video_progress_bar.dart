import 'package:flutter/material.dart';
import 'package:video_player/controller/controller.dart';
import 'package:video_player/controls/progress_bar_painter.dart';

class MaterialVideoProgressBar extends StatefulWidget {
  MaterialVideoProgressBar({
    Key? key,
    this.dragStart,
    this.dragEnd,
  }) : super(key: key);

  final VoidCallback? dragStart;
  final VoidCallback? dragEnd;

  @override
  State<MaterialVideoProgressBar> createState() {
    return _VideoProgressBarState();
  }
}

class _VideoProgressBarState
    extends VideoPlayerControllerState<MaterialVideoProgressBar> {
  Duration? _seekingPosition;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onHorizontalDragStart: (DragStartDetails details) {
        if (controller.configuration.controlsConfiguration.disableSeek) return;
        if (controller.value.initialized != true) {
          return;
        }
        widget.dragStart?.call();
      },
      onHorizontalDragUpdate: (DragUpdateDetails details) {
        if (controller.configuration.controlsConfiguration.disableSeek) return;
        if (controller.value.initialized != true) {
          return;
        }
        seekToRelativePosition(details.globalPosition);
      },
      onHorizontalDragEnd: (DragEndDetails details) async {
        if (controller.configuration.controlsConfiguration.disableSeek) return;
        if (controller.value.initialized != true) {
          return;
        }
        await controller.seekTo(_seekingPosition);
        _seekingPosition = null;
        widget.dragEnd?.call();
      },
      child: Center(
        child: Container(
          height: MediaQuery.of(context).size.height / 2,
          width: MediaQuery.of(context).size.width,
          color: Colors.transparent,
          child: CustomPaint(
            painter: ProgressBarPainter(
              colors:
                  controller.configuration.controlsConfiguration.progressColors,
              position:
                  _seekingPosition ?? lastValue?.position ?? Duration.zero,
              duration: controller.value.duration,
              buffered: controller.value.buffered,
            ),
          ),
        ),
      ),
    );
  }

  @override
  bool willRebuild(
    VideoPlayerValue? oldValue,
    VideoPlayerValue newValue,
  ) {
    return newValue.eventType == VideoPlayerEventType.initialized ||
        newValue.eventType == VideoPlayerEventType.positionChanged;
  }

  void seekToRelativePosition(Offset globalPosition) {
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject != null) {
      final box = renderObject as RenderBox;
      final Offset tapPos = box.globalToLocal(globalPosition);
      final double relative = tapPos.dx / box.size.width;
      if (relative >= 0 && relative <= 1) {
        final Duration position = controller.value.duration! * relative;
        _seekingPosition = position;
        setState(() {});
      }
    }
  }
}
