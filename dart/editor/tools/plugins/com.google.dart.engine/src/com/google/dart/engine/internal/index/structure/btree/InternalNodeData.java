/*
 * Copyright (c) 2014, the Dart project authors.
 * 
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 * 
 * http://www.eclipse.org/legal/epl-v10.html
 * 
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
package com.google.dart.engine.internal.index.structure.btree;

import java.util.List;

/**
 * A container with information about an internal node.
 * 
 * @coverage dart.engine.index.structure
 */
public class InternalNodeData<K, N> {
  public final List<K> keys;
  public final List<N> children;

  public InternalNodeData(List<K> keys, List<N> children) {
    this.keys = keys;
    this.children = children;
  }
}
