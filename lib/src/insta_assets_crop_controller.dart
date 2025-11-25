import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fraction/fraction.dart';
import 'package:image/image.dart' as img;
import 'package:insta_assets_crop/insta_assets_crop.dart';
import 'package:insta_assets_picker/insta_assets_picker.dart';

/// Uses [InstaAssetsCropSingleton] to keep crop parameters in memory until the picker is disposed
/// Similar to [Singleton] class from `wechat_assets_picker` package
/// used only when [keepScrollOffset] is set to `true`
class InstaAssetsCropSingleton {
  const InstaAssetsCropSingleton._();

  static List<InstaAssetsCropData> cropParameters = [];
}

class InstaAssetsExportData {
  const InstaAssetsExportData({
    required this.croppedFile,
    required this.selectedData,
  });

  /// The cropped file, can be null if the asset is not an image or if the
  /// exportation was skipped ([skipCropOnComplete]=true)
  final File? croppedFile;

  /// The selected data, contains the asset and it's crop values
  final InstaAssetsCropData selectedData;
}

/// Contains all the parameters of the exportation
class InstaAssetsExportDetails {
  /// The export result, containing the selected assets, crop parameters
  /// and possible crop file.
  final List<InstaAssetsExportData> data;

  /// The selected thumbnails, can be provided to the picker to preselect those assets
  final List<AssetEntity> selectedAssets;

  /// The selected [aspectRatio]
  final double aspectRatio;

  /// The [progress] param represents progress indicator between `0.0` and `1.0`.
  final double progress;

  const InstaAssetsExportDetails({
    required this.data,
    required this.selectedAssets,
    required this.aspectRatio,
    required this.progress,
  });
}

/// The crop parameters state, can be used at exportation or to load the crop view
class InstaAssetsCropData {
  final AssetEntity asset;
  final CropInternal? cropParam;

  // export crop params
  final double scale;
  final int rotation; // 0, 1, 2, 3 (quarter turns)
  final Rect? area;

  /// Returns crop filter for ffmpeg in "out_w:out_h:x:y" format
  String? get ffmpegCrop {
    final area = this.area;
    if (area == null) return null;

    final w = area.width * asset.orientatedWidth;
    final h = area.height * asset.orientatedHeight;
    final x = area.left * asset.orientatedWidth;
    final y = area.top * asset.orientatedHeight;

    return '$w:$h:$x:$y';
  }

  /// Returns scale filter for ffmpeg in "iw*[scale]:ih*[scale]" format
  String? get ffmpegScale {
    final scale = cropParam?.scale;
    if (scale == null) return null;

    return 'iw*$scale:ih*$scale';
  }

  /// Returns rotate filter for ffmpeg in "rotate=angle" format
  String? get ffmpegRotate {
    if (rotation == 0) return null;
    return 'rotate=${rotation * 90 * math.pi / 180}';
  }

  const InstaAssetsCropData({
    required this.asset,
    required this.cropParam,
    this.scale = 1.0,
    this.rotation = 0,
    this.area,
  });

  static InstaAssetsCropData fromState({
    required AssetEntity asset,
    required CropState? cropState,
    int rotation = 0,
  }) {
    return InstaAssetsCropData(
      asset: asset,
      cropParam: cropState?.internalParameters,
      scale: cropState?.scale ?? 1.0,
      rotation: rotation,
      area: cropState?.area,
    );
  }
}

/// The controller that handles the exportation and save the state of the selected assets crop parameters
class InstaAssetsCropController {
  InstaAssetsCropController(this.keepMemory, this.cropDelegate)
      : cropRatioIndex = ValueNotifier<int>(0);

  /// The index of the selected aspectRatio among the possibilities
  final ValueNotifier<int> cropRatioIndex;

  /// Whether the asset in the crop view is loaded
  final ValueNotifier<bool> isCropViewReady = ValueNotifier<bool>(false);

  /// The asset [AssetEntity] currently displayed in the crop view
  final ValueNotifier<AssetEntity?> previewAsset =
      ValueNotifier<AssetEntity?>(null);

  /// The rotation of the crop view (quarter turns)
  final ValueNotifier<int> rotation = ValueNotifier<int>(0);

  /// Options related to crop
  final InstaAssetCropDelegate cropDelegate;

  /// List of all the crop parameters set by the user
  List<InstaAssetsCropData> _cropParameters = [];

  /// Whether if [_cropParameters] should be saved in the cache to use when the picker
  /// is open with [InstaAssetPicker.restorableAssetsPicker]
  final bool keepMemory;

  void dispose() {
    clear();
    isCropViewReady.dispose();
    cropRatioIndex.dispose();
    previewAsset.dispose();
    rotation.dispose();
  }

  double get aspectRatio {
    assert(cropDelegate.cropRatios.isNotEmpty,
        'The list of supported crop ratios cannot be empty.');
    return cropDelegate.cropRatios[cropRatioIndex.value];
  }

  String get aspectRatioString {
    final r = aspectRatio;
    if (r == 1) return '1:1';
    return Fraction.fromDouble(r).reduce().toString().replaceFirst('/', ':');
  }

  /// Set the next available index as the selected crop ratio
  void nextCropRatio() {
    if (cropRatioIndex.value < cropDelegate.cropRatios.length - 1) {
      cropRatioIndex.value = cropRatioIndex.value + 1;
    } else {
      cropRatioIndex.value = 0;
    }
  }

  void rotate() {
    rotation.value = (rotation.value + 1) % 4;
  }

  void applyRotation(AssetEntity asset) {
    final index = cropParameters.indexWhere((e) => e.asset == asset);
    rotation.value = (index != -1) ? cropParameters[index].rotation : 0;
  }

  /// Use [_cropParameters] when [keepMemory] is `false`, otherwise use [InstaAssetsCropSingleton.cropParameters]
  List<InstaAssetsCropData> get cropParameters =>
      keepMemory ? InstaAssetsCropSingleton.cropParameters : _cropParameters;

  /// Save the list of crop parameters
  /// if [keepMemory] save list memory or simply in the controller
  void updateStoreCropParam(List<InstaAssetsCropData> list) {
    if (keepMemory) {
      InstaAssetsCropSingleton.cropParameters = list;
    } else {
      _cropParameters = list;
    }
  }

  /// Clear all the saved crop parameters
  void clear() {
    updateStoreCropParam([]);
    previewAsset.value = null;
    rotation.value = 0;
  }

  /// When the preview asset is changed, save the crop parameters of the previous asset
  void onChange(
    AssetEntity? saveAsset,
    CropState? saveCropState,
    List<AssetEntity> selectedAssets,
  ) {
    final List<InstaAssetsCropData> newList = [];

    for (final asset in selectedAssets) {
      // get the already saved crop parameters if exists
      final savedCropAsset = get(asset);

      // if it is the asseet to save & the crop parameters exists
      if (asset == saveAsset && saveAsset != null) {
        // add the new parameters
        newList.add(InstaAssetsCropData.fromState(
          asset: saveAsset,
          cropState: saveCropState,
          rotation: rotation.value,
        ));
        // if it is not the asset to save and no crop parameter exists
      } else if (savedCropAsset == null) {
        // set empty crop parameters
        newList
            .add(InstaAssetsCropData.fromState(asset: asset, cropState: null));
      } else {
        // keep existing crop parameters
        newList.add(savedCropAsset);
      }
    }

    // overwrite the crop parameters list
    updateStoreCropParam(newList);
  }

  /// Returns the crop parametes [InstaAssetsCropData] of the given asset
  InstaAssetsCropData? get(AssetEntity asset) {
    final index = cropParameters.indexWhere((e) => e.asset == asset);
    if (index == -1) return null;
    return cropParameters[index];
  }

  /// Apply all the crop parameters to the list of [selectedAssets]
  /// and returns the exportation as a [Stream]
  Stream<InstaAssetsExportDetails> exportCropFiles(
    List<AssetEntity> selectedAssets, {
    bool skipCrop = false,
  }) async* {
    final List<InstaAssetsExportData> data = [];

    /// Returns the [InstaAssetsExportDetails] with given progress value [p]
    InstaAssetsExportDetails makeDetail(double p) => InstaAssetsExportDetails(
          data: data,
          selectedAssets: selectedAssets,
          aspectRatio: aspectRatio,
          progress: p,
        );

    // start progress
    yield makeDetail(0);
    final List<InstaAssetsCropData> list = cropParameters;

    final step = 1 / list.length;

    for (int i = 0; i < list.length; i++) {
      final asset = list[i].asset;

      if (skipCrop || asset.type != AssetType.image) {
        data.add(
            InstaAssetsExportData(croppedFile: null, selectedData: list[i]));
      } else {
        final file = await asset.originFile;

        final scale = list[i].scale;
        final area = list[i].area;
        final rotation = list[i].rotation;

        if (file == null) {
          throw 'error file is null';
        }

        // makes the sample file to not be too small
        var sampledFile = await InstaAssetsCrop.sampleImage(
          file: file,
          preferredSize: (cropDelegate.preferredSize / scale).round(),
        );

        // rotate the image if needed
        if (rotation != 0) {
          final bytes = await sampledFile.readAsBytes();
          final image = img.decodeImage(bytes);

          if (image != null) {
            final rotatedImage = img.copyRotate(image, angle: rotation * 90);
            final rotatedBytes = img.encodeJpg(rotatedImage);
            final rotatedFile = await File(
                    '${sampledFile.parent.path}/rotated_${DateTime.now().millisecondsSinceEpoch}.jpg')
                .writeAsBytes(rotatedBytes);
            sampledFile.delete();
            sampledFile = rotatedFile;
          }
        }

        if (area == null) {
          data.add(InstaAssetsExportData(
              croppedFile: sampledFile, selectedData: list[i]));
        } else {
          // crop the file with the area selected
          final croppedFile =
              await InstaAssetsCrop.cropImage(file: sampledFile, area: area);
          // delete the not needed sample file
          sampledFile.delete();

          data.add(InstaAssetsExportData(
              croppedFile: croppedFile, selectedData: list[i]));
        }
      }

      // increase progress
      final progress = (i + 1) * step;
      if (progress < 1) {
        yield makeDetail(progress);
      }
    }
    // complete progress
    yield makeDetail(1);
  }
}
