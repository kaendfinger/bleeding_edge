// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library barback.test.utils;

import 'dart:async';
import 'dart:collection';
import 'dart:io';

import 'package:barback/barback.dart';
import 'package:barback/src/asset_set.dart';
import 'package:barback/src/cancelable_future.dart';
import 'package:barback/src/utils.dart';
import 'package:path/path.dart' as pathos;
import 'package:scheduled_test/scheduled_test.dart';
import 'package:stack_trace/stack_trace.dart';
import 'package:unittest/compact_vm_config.dart';

export 'transformer/bad.dart';
export 'transformer/check_content.dart';
export 'transformer/create_asset.dart';
export 'transformer/many_to_one.dart';
export 'transformer/mock.dart';
export 'transformer/one_to_many.dart';
export 'transformer/rewrite.dart';

var _configured = false;

MockProvider _provider;
Barback _barback;

/// Calls to [buildShouldSucceed] and [buildShouldFail] set expectations on
/// successive [BuildResult]s from [_barback]. This keeps track of how many
/// calls have already been made so later calls know which result to look for.
int _nextBuildResult;

void initConfig() {
  if (_configured) return;
  _configured = true;
  useCompactVMConfiguration();
}

/// Creates a new [PackageProvider] and [PackageGraph] with the given [assets]
/// and [transformers].
///
/// This graph is used internally by most of the other functions in this
/// library so you must call it in the test before calling any of the other
/// functions.
///
/// [assets] may either be an [Iterable] or a [Map]. If it's an [Iterable],
/// each element may either be an [AssetId] or a string that can be parsed to
/// one. If it's a [Map], each key should be a string that can be parsed to an
/// [AssetId] and the value should be a string defining the contents of that
/// asset.
///
/// [transformers] is a map from package names to the transformers for each
/// package.
void initGraph([assets,
    Map<String, Iterable<Iterable<Transformer>>> transformers]) {
  if (assets == null) assets = [];
  if (transformers == null) transformers = {};

  _provider = new MockProvider(assets, transformers);
  _barback = new Barback(_provider);
  _nextBuildResult = 0;
}

/// Updates [assets] in the current [PackageProvider].
///
/// Each item in the list may either be an [AssetId] or a string that can be
/// parsed as one.
void updateSources(Iterable assets) {
  assets = _parseAssets(assets);
  schedule(() => _barback.updateSources(assets),
      "updating ${assets.join(', ')}");
}

/// Updates [assets] in the current [PackageProvider].
///
/// Each item in the list may either be an [AssetId] or a string that can be
/// parsed as one. Unlike [updateSources], this is not automatically scheduled
/// and will be run synchronously when called.
void updateSourcesSync(Iterable assets) =>
    _barback.updateSources(_parseAssets(assets));

/// Removes [assets] from the current [PackageProvider].
///
/// Each item in the list may either be an [AssetId] or a string that can be
/// parsed as one.
void removeSources(Iterable assets) {
  assets = _parseAssets(assets);
  schedule(() => _barback.removeSources(assets),
      "removing ${assets.join(', ')}");
}

/// Removes [assets] from the current [PackageProvider].
///
/// Each item in the list may either be an [AssetId] or a string that can be
/// parsed as one. Unlike [removeSources], this is not automatically scheduled
/// and will be run synchronously when called.
void removeSourcesSync(Iterable assets) =>
    _barback.removeSources(_parseAssets(assets));

/// Parse a list of strings or [AssetId]s into a list of [AssetId]s.
List<AssetId> _parseAssets(Iterable assets) {
  return assets.map((asset) {
    if (asset is String) return new AssetId.parse(asset);
    return asset;
  }).toList();
}

/// Schedules a change to the contents of an asset identified by [name] to
/// [contents].
///
/// Does not update it in the graph.
void modifyAsset(String name, String contents) {
  schedule(() {
    _provider._modifyAsset(name, contents);
  }, "modify asset $name");
}

/// Schedules an error to be generated when loading the asset identified by
/// [name].
///
/// Does not update the asset in the graph.
void setAssetError(String name) {
  schedule(() {
    _provider._setAssetError(name);
  }, "set error for asset $name");
}

/// Schedules a pause of the internally created [PackageProvider].
///
/// All asset requests that the [PackageGraph] makes to the provider after this
/// will not complete until [resumeProvider] is called.
void pauseProvider() {
  schedule(() => _provider._pause(), "pause provider");
}

/// Schedules an unpause of the provider after a call to [pauseProvider] and
/// allows all pending asset loads to finish.
void resumeProvider() {
  schedule(() => _provider._resume(), "resume provider");
}

/// Asserts that the current build step shouldn't have finished by this point in
/// the schedule.
///
/// This uses the same build counter as [buildShouldSucceed] and
/// [buildShouldFail], so those can be used to validate build results before and
/// after this.
void buildShouldNotBeDone() {
  _futureShouldNotCompleteUntil(
      _barback.results.elementAt(_nextBuildResult),
      schedule(() => pumpEventQueue(), "build should not terminate"),
      "build");
}

/// Expects that the next [BuildResult] is a build success.
void buildShouldSucceed() {
  expect(_getNextBuildResult("build should succeed").then((result) {
    result.errors.forEach(currentSchedule.signalError);
    expect(result.succeeded, isTrue);
  }), completes);
}

/// Expects that the next [BuildResult] emitted is a failure.
///
/// [matchers] is a list of matchers to match against the errors that caused the
/// build to fail. Every matcher is expected to match an error, but the order of
/// matchers is unimportant.
void buildShouldFail(List matchers) {
  expect(_getNextBuildResult("build should fail").then((result) {
    expect(result.succeeded, isFalse);
    expect(result.errors.length, equals(matchers.length));
    for (var matcher in matchers) {
      expect(result.errors, contains(matcher));
    }
  }), completes);
}

Future<BuildResult> _getNextBuildResult(String description) {
  var result = currentSchedule.wrapFuture(
      _barback.results.elementAt(_nextBuildResult++));
  return schedule(() => result, description);
}

/// Schedules an expectation that the graph will deliver an asset matching
/// [name] and [contents].
///
/// If [contents] is omitted, defaults to the asset's filename without an
/// extension (which is the same default that [initGraph] uses).
void expectAsset(String name, [String contents]) {
  var id = new AssetId.parse(name);

  if (contents == null) {
    contents = pathos.basenameWithoutExtension(id.path);
  }

  schedule(() {
    return _barback.getAssetById(id).then((asset) {
      // TODO(rnystrom): Make an actual Matcher class for this.
      expect(asset.id, equals(id));
      expect(asset.readAsString(), completion(equals(contents)));
    });
  }, "get asset $name");
}

/// Schedules an expectation that the graph will not find an asset matching
/// [name].
void expectNoAsset(String name) {
  var id = new AssetId.parse(name);

  // Make sure the future gets the error.
  schedule(() {
    return _barback.getAssetById(id).then((asset) {
      fail("Should have thrown error but got $asset.");
    }).catchError((error) {
      expect(error, new isInstanceOf<AssetNotFoundException>());
      expect(error.id, equals(id));
    });
  }, "get asset $name");
}

/// Schedules an expectation that a [getAssetById] call for the given asset
/// won't terminate at this point in the schedule.
void expectAssetDoesNotComplete(String name) {
  var id = new AssetId.parse(name);

  schedule(() {
    return _futureShouldNotCompleteUntil(
        _barback.getAssetById(id),
        pumpEventQueue(),
        "asset $id");
  }, "asset $id should not complete");
}

/// Returns a matcher for an [AssetNotFoundException] with the given [id].
Matcher isAssetNotFoundException(String name) {
  var id = new AssetId.parse(name);
  return allOf(
      new isInstanceOf<AssetNotFoundException>(),
      predicate((error) => error.id == id, 'id == $name'));
}

/// Returns a matcher for an [AssetCollisionException] with the given [id].
Matcher isAssetCollisionException(String name) {
  var id = new AssetId.parse(name);
  return allOf(
      new isInstanceOf<AssetCollisionException>(),
      predicate((error) => error.id == id, 'id == $name'));
}

/// Returns a matcher for a [MissingInputException] with the given [id].
Matcher isMissingInputException(String name) {
  var id = new AssetId.parse(name);
  return allOf(
      new isInstanceOf<MissingInputException>(),
      predicate((error) => error.id == id, 'id == $name'));
}

/// Returns a matcher for an [InvalidOutputException] with the given id and
/// package name.
Matcher isInvalidOutputException(String package, String name) {
  var id = new AssetId.parse(name);
  return allOf(
      new isInstanceOf<InvalidOutputException>(),
      predicate((error) => error.package == package, 'package is $package'),
      predicate((error) => error.id == id, 'id == $name'));
}

/// Returns a matcher for a [MockLoadException] with the given [id].
Matcher isMockLoadException(String name) {
  var id = new AssetId.parse(name);
  return allOf(
      new isInstanceOf<MockLoadException>(),
      predicate((error) => error.id == id, 'id == $name'));
}

/// Asserts that [future] shouldn't complete until after [delay] completes.
///
/// Once [delay] completes, the output of [future] is ignored, even if it's an
/// error.
///
/// [description] should describe [future].
Future _futureShouldNotCompleteUntil(Future future, Future delay,
    String description) {
  var trace = new Trace.current();
  var cancelable = new CancelableFuture(future);
  cancelable.then((result) {
    currentSchedule.signalError(
        new Exception("Expected $description not to complete here, but it "
            "completed with result: $result"),
        trace);
  }).catchError((error) {
    currentSchedule.signalError(error);
  });

  return delay.then((_) => cancelable.cancel());
}

/// An [AssetProvider] that provides the given set of assets.
class MockProvider implements PackageProvider {
  Iterable<String> get packages => _packages.keys;

  Map<String, _MockPackage> _packages;

  /// The set of assets for which [MockLoadException]s should be emitted if
  /// they're loaded.
  final _errors = new Set<AssetId>();

  /// The completer that [getAsset()] is waiting on to complete when paused.
  ///
  /// If `null` it will return the asset immediately.
  Completer _pauseCompleter;

  /// Tells the provider to wait during [getAsset] until [complete()]
  /// is called.
  ///
  /// Lets you test the asynchronous behavior of loading.
  void _pause() {
    _pauseCompleter = new Completer();
  }

  void _resume() {
    _pauseCompleter.complete();
    _pauseCompleter = null;
  }

  MockProvider(assets,
      Map<String, Iterable<Iterable<Transformer>>> transformers) {
    var assetList;
    if (assets is Map) {
      assetList = assets.keys.map((asset) {
        var id = new AssetId.parse(asset);
        return new _MockAsset(id, assets[asset]);
      });
    } else if (assets is Iterable) {
      assetList = assets.map((asset) {
        var id = new AssetId.parse(asset);
        var contents = pathos.basenameWithoutExtension(id.path);
        return new _MockAsset(id, contents);
      });
    }

    _packages = mapMapValues(groupBy(assetList, (asset) => asset.id.package),
        (package, assets) {
      var packageTransformers = transformers[package];
      if (packageTransformers == null) packageTransformers = [];
      return new _MockPackage(
          new AssetSet.from(assets), packageTransformers.toList());
    });

    // If there are no assets or transformers, add a dummy package. This better
    // simulates the real world, where there'll always be at least the
    // entrypoint package.
    if (_packages.isEmpty) {
      _packages = {"app": new _MockPackage(new AssetSet(), [])};
    }
  }

  void _modifyAsset(String name, String contents) {
    var id = new AssetId.parse(name);
    _errors.remove(id);
    _packages[id.package].assets[id].contents = contents;
  }

  void _setAssetError(String name) => _errors.add(new AssetId.parse(name));

  List<AssetId> listAssets(String package, {String within}) {
    if (within != null) {
      throw new UnimplementedError("Doesn't handle 'within' yet.");
    }

    return _packages[package].assets.map((asset) => asset.id);
  }

  Iterable<Iterable<Transformer>> getTransformers(String package) {
    var mockPackage = _packages[package];
    if (mockPackage == null) {
      throw new ArgumentError("No package named $package.");
    }
    return mockPackage.transformers;
  }

  Future<Asset> getAsset(AssetId id) {
    // Eagerly load the asset so we can test an asset's value changing between
    // when a load starts and when it finishes.
    var package = _packages[id.package];
    var asset;
    if (package != null) asset = package.assets[id];

    var hasError = _errors.contains(id);

    var future;
    if (_pauseCompleter != null) {
      future = _pauseCompleter.future;
    } else {
      future = new Future.value();
    }

    return future.then((_) {
      if (hasError) throw new MockLoadException(id);
      if (asset == null) throw new AssetNotFoundException(id);
      return asset;
    });
  }
}

/// Error thrown for assets with [setAssetError] set.
class MockLoadException implements Exception {
  final AssetId id;

  MockLoadException(this.id);

  String toString() => "Error loading $id.";
}

/// Used by [MockProvider] to keep track of which assets and transformers exist
/// for each package.
class _MockPackage {
  final AssetSet assets;
  final List<List<Transformer>> transformers;

  _MockPackage(this.assets, Iterable<Iterable<Transformer>> transformers)
      : transformers = transformers.map((phase) => phase.toList()).toList();
}

/// An implementation of [Asset] that never hits the file system.
class _MockAsset implements Asset {
  final AssetId id;
  String contents;

  _MockAsset(this.id, this.contents);

  Future<String> readAsString({Encoding encoding}) =>
      new Future.value(contents);

  Stream<List<int>> read() => throw new UnimplementedError();

  String toString() => "MockAsset $id $contents";
}
