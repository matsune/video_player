import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:video_player/abr/abr.dart';
import 'package:video_player/controller/controller.dart';
import 'package:video_player/controls/controls.dart';
import 'package:video_player/subtitles/subtitles.dart';

class MoreButton extends StatefulWidget {
  const MoreButton({super.key});

  @override
  State<MoreButton> createState() => MoreButtonState();
}

class MoreButtonState extends VideoPlayerControllerState<MoreButton> {
  @override
  Widget build(BuildContext context) {
    final controlsConfiguration =
        controller.configuration.controlsConfiguration;
    return MaterialClickableWidget(
      onTap: () {
        onTap();
        controller.controlsEventStreamController
            .add(ControlsEvent(eventType: ControlsEventType.onTapMore));
      },
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          controlsConfiguration.overflowMenuIcon,
          color: controlsConfiguration.iconsColor,
        ),
      ),
    );
  }

  onTap() {
    _showMaterialBottomSheet([_buildMoreOptionsList()]);
  }

  void _showMaterialBottomSheet(List<Widget> children) {
    showModalBottomSheet<void>(
      backgroundColor: Colors.transparent,
      context: context,
      builder: (context) {
        return SafeArea(
          top: false,
          child: SingleChildScrollView(
            physics: const BouncingScrollPhysics(),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              decoration: BoxDecoration(
                color: controlsConfiguration.overflowModalColor,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(24.0),
                  topRight: Radius.circular(24.0),
                ),
              ),
              child: Column(
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildMoreOptionsList() {
    return SingleChildScrollView(
      child: Container(
        child: Column(
          children: [
            _buildMoreOptionsListRow(
              icon: controlsConfiguration.playbackSpeedIcon,
              name: "Playback Speed",
              onTap: () {
                controller.controlsEventStreamController.add(
                  ControlsEvent(
                      eventType: ControlsEventType.onTapPlaybackSpeedMenu),
                );
                Navigator.of(context).pop();
                _showSpeedChooserWidget();
              },
            ),
            if (controller.subtitlesController.subtitlesSourceList.isNotEmpty)
              _buildMoreOptionsListRow(
                icon: controlsConfiguration.subtitlesIcon,
                name: "Subtitles",
                onTap: () {
                  controller.controlsEventStreamController.add(
                    ControlsEvent(
                        eventType: ControlsEventType.onTapSubtitlesMenu),
                  );
                  Navigator.of(context).pop();
                  _showSubtitlesSelectionWidget();
                },
              ),
            _buildMoreOptionsListRow(
              icon: controlsConfiguration.qualitiesIcon,
              name: "Quality",
              onTap: () {
                controller.controlsEventStreamController.add(
                  ControlsEvent(eventType: ControlsEventType.onTapQualityMenu),
                );
                Navigator.of(context).pop();
                _showQualitiesSelectionWidget();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMoreOptionsListRow({
    required IconData icon,
    required String name,
    required void Function() onTap,
  }) {
    return MaterialClickableWidget(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        child: Row(
          children: [
            const SizedBox(width: 8),
            Icon(
              icon,
              color: controlsConfiguration.overflowMenuIconsColor,
            ),
            const SizedBox(width: 16),
            Text(
              name,
              style: _getOverflowMenuElementTextStyle(false),
            ),
          ],
        ),
      ),
    );
  }

  TextStyle _getOverflowMenuElementTextStyle(bool isSelected) {
    return TextStyle(
      fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
      color: isSelected
          ? controlsConfiguration.overflowModalTextColor
          : controlsConfiguration.overflowModalTextColor.withOpacity(0.7),
    );
  }

  void _showSpeedChooserWidget() {
    _showMaterialBottomSheet([
      _buildSpeedRow(0.25),
      _buildSpeedRow(0.5),
      _buildSpeedRow(0.75),
      _buildSpeedRow(1.0),
      _buildSpeedRow(1.25),
      _buildSpeedRow(1.5),
      _buildSpeedRow(1.75),
      _buildSpeedRow(2.0),
    ]);
  }

  Widget _buildSpeedRow(double value) {
    final bool isSelected = lastValue?.playbackRate == value;

    return MaterialClickableWidget(
      onTap: () {
        Navigator.of(context).pop();
        controller.setPlaybackRate(value);
        controller.controlsEventStreamController.add(
          ControlsEvent(
            eventType: ControlsEventType.onTapPlaybackSpeedValue,
            speedValue: value,
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            SizedBox(width: isSelected ? 8 : 16),
            Visibility(
                visible: isSelected,
                child: Icon(
                  Icons.check_outlined,
                  color: controlsConfiguration.overflowModalTextColor,
                )),
            const SizedBox(width: 16),
            Text(
              "$value x",
              style: _getOverflowMenuElementTextStyle(isSelected),
            )
          ],
        ),
      ),
    );
  }

  void _showSubtitlesSelectionWidget() {
    final subtitles = controller.subtitlesController.subtitlesSourceList;
    final noneSubtitlesElementExists = subtitles.firstWhereOrNull(
            (source) => source.type == VideoPlayerSubtitlesSourceType.none) !=
        null;
    if (!noneSubtitlesElementExists) {
      subtitles.add(VideoPlayerSubtitlesSource(
          type: VideoPlayerSubtitlesSourceType.none, name: 'None'));
    }

    _showMaterialBottomSheet(
      subtitles
          .asMap()
          .entries
          .map((entry) => _buildSubtitlesSourceRow(entry.key, entry.value))
          .toList(),
    );
  }

  Widget _buildSubtitlesSourceRow(
    int index,
    VideoPlayerSubtitlesSource subtitlesSource,
  ) {
    final bool isSelected = subtitlesSource ==
        controller.subtitlesController.selectedSubtitlesSource;

    return MaterialClickableWidget(
      onTap: () {
        Navigator.of(context).pop();
        controller.subtitlesController
            .setSubtitleSource(index, isUserAction: true);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            SizedBox(width: isSelected ? 8 : 16),
            Visibility(
              visible: isSelected,
              child: Icon(
                Icons.check_outlined,
                color: controlsConfiguration.overflowModalTextColor,
              ),
            ),
            const SizedBox(width: 16),
            Text(
              subtitlesSource.type == VideoPlayerSubtitlesSourceType.none
                  ? "None"
                  : subtitlesSource.name ?? "Default",
              style: _getOverflowMenuElementTextStyle(isSelected),
            ),
          ],
        ),
      ),
    );
  }

  String? defaultQualitySelectable(AbrTrack track) {
    final int width = track.width ?? 0;
    final int height = track.height ?? 0;
    final int bitrate = track.bitrate ?? 0;
    if (width > 0 && height > 0 && bitrate > 0) {
      return "${height}p";
    } else {
      return null;
    }
  }

  void _showQualitiesSelectionWidget() {
    final rows = controller.tracksController.abrTracks
        .map((track) {
          final selectableFn =
              controller.configuration.quarityTrackSelectable ??
                  defaultQualitySelectable;
          final displayName = selectableFn(track);
          return (track, displayName);
        })
        .where((e) => e.$2 != null)
        .map((e) => _buildTrackRow(e.$1, e.$2!))
        .toList();
    rows.add(
      _buildTrackRow(AbrTrack.defaultTrack(), "Auto"),
    );
    _showMaterialBottomSheet(rows);
  }

  Widget _buildTrackRow(AbrTrack track, String displayName) {
    final selectedTrack = controller.tracksController.selectedTrack;
    final bool isSelected = (selectedTrack != null && selectedTrack == track) ||
        (selectedTrack == null &&
            track.width == 0 &&
            track.height == 0 &&
            track.bitrate == 0);

    return MaterialClickableWidget(
      onTap: () {
        Navigator.of(context).pop();
        controller.tracksController.selectTrack(track);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
        child: Row(
          children: [
            SizedBox(width: isSelected ? 8 : 16),
            Visibility(
                visible: isSelected,
                child: Icon(
                  Icons.check_outlined,
                  color: controlsConfiguration.overflowModalTextColor,
                )),
            const SizedBox(width: 16),
            Text(
              displayName,
              style: _getOverflowMenuElementTextStyle(isSelected),
            ),
          ],
        ),
      ),
    );
  }
}
