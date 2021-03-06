// Copyright (c) 2013, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of vmservice;

// A service client.
abstract class Client {
  final VMService service;
  final bool sendEvents;

  Client(this.service, { bool sendEvents: true })
      : this.sendEvents = sendEvents {
    service._addClient(this);
  }

  /// When implementing, call [close] when the network connection closes.
  void close() {
    service._removeClient(this);
  }

  /// Call to process a message. Response will be posted with 'seq'.
  void onMessage(var seq, Message message) {
    try {
      // Send message to service.
      service.route(message).then((response) {
        // Call post when the response arrives.
        post(seq, response);
      });
    } catch (e, st) {
      message.setErrorResponse('Internal error: $e');
      post(seq, message.response);
    }
  }

  // Sends a result to the client.  Implemented in subclasses.
  void post(var seq, dynamic result);

  dynamic toJson() {
    return {
    };
  }
}
