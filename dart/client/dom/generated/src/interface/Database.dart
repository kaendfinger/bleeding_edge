// Copyright (c) 2011, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// WARNING: Do not edit - generated code.

interface Database {

  String get version();

  void changeVersion(String oldVersion, String newVersion, SQLTransactionCallback callback = null, SQLTransactionErrorCallback errorCallback = null, VoidCallback successCallback = null);

  void readTransaction(SQLTransactionCallback callback, SQLTransactionErrorCallback errorCallback = null, VoidCallback successCallback = null);

  void transaction(SQLTransactionCallback callback, SQLTransactionErrorCallback errorCallback = null, VoidCallback successCallback = null);
}
