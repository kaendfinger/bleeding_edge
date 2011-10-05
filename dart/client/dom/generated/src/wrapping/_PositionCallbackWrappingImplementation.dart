// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// WARNING: Do not edit - generated code.

class _PositionCallbackWrappingImplementation extends DOMWrapperBase implements PositionCallback {
  _PositionCallbackWrappingImplementation() : super() {}

  static create__PositionCallbackWrappingImplementation() native {
    return new _PositionCallbackWrappingImplementation();
  }

  bool handleEvent(Geoposition position) {
    return _handleEvent(this, position);
  }
  static bool _handleEvent(receiver, position) native;

  String get typeName() { return "PositionCallback"; }
}
