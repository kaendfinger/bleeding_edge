// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of dart2js;

class EnqueueTask extends CompilerTask {
  final ResolutionEnqueuer resolution;
  final CodegenEnqueuer codegen;

  /// A reverse map from name to *all* elements with that name, not
  /// just instance members of instantiated classes.
  final Map<String, Link<Element>> allElementsByName
      = new Map<String, Link<Element>>();

  void ensureAllElementsByName() {
    if (!allElementsByName.isEmpty) return;

    void addMemberByName(Element element) {
      element = element.declaration;
      String name = element.name.slowToString();
      Link<Element> members = const Link<Element>();
      if (element.isLibrary()) {
        LibraryElementX library = element;
        // Don't include private implementation libraries.  These
        // libraries contain special classes that cause problems
        // in other parts of the resolver (in particular Null and Void).
        // TODO(ahe): Consider lifting this restriction.
        if (!library.isInternalLibrary) {
          members = library.localMembers;
          // TODO(ahe): Is this right?  Is this necessary?
          name = library.getLibraryOrScriptName();
        }
      } else if (element.isClass() && !element.isMixinApplication) {
        // TODO(ahe): Investigate what makes mixin applications crash
        // this method.
        ClassElementX cls = element;
        cls.ensureResolved(compiler);
        members = cls.localMembers;
        for (var link = cls.computeTypeParameters(compiler);
             !link.isEmpty;
             link = link.tail) {
          addMemberByName(link.head.element);
        }
      } else if (element.isConstructor()) {
        SourceString source = Elements.deconstructConstructorName(
            element.name, element.getEnclosingClass());
        if (source == null) {
          // source is null for unnamed constructors.
          name = '';
        } else {
          name = source.slowToString();
        }
      }
      allElementsByName[name] = allElementsByName.putIfAbsent(
          name, () => const Link<Element>()).prepend(element);
      for (var link = members; !link.isEmpty; link = link.tail) {
        addMemberByName(link.head);
      }
    }

    compiler.libraries.values.forEach(addMemberByName);
  }

  String get name => 'Enqueue';

  EnqueueTask(Compiler compiler)
    : resolution = new ResolutionEnqueuer(
          compiler, compiler.backend.createItemCompilationContext),
      codegen = new CodegenEnqueuer(
          compiler, compiler.backend.createItemCompilationContext),
      super(compiler) {
    codegen.task = this;
    resolution.task = this;

    codegen.nativeEnqueuer = compiler.backend.nativeCodegenEnqueuer(codegen);
    resolution.nativeEnqueuer =
        compiler.backend.nativeResolutionEnqueuer(resolution);
  }
}

abstract class Enqueuer {
  final String name;
  final Compiler compiler; // TODO(ahe): Remove this dependency.
  final Function itemCompilationContextCreator;
  final Map<String, Link<Element>> instanceMembersByName
      = new Map<String, Link<Element>>();
  final Map<String, Link<Element>> instanceFunctionsByName
      = new Map<String, Link<Element>>();
  final Set<ClassElement> seenClasses = new Set<ClassElement>();
  final Universe universe = new Universe();

  bool queueIsClosed = false;
  EnqueueTask task;
  native.NativeEnqueuer nativeEnqueuer;  // Set by EnqueueTask

  bool hasEnqueuedEverything = false;

  Enqueuer(this.name, this.compiler,
           ItemCompilationContext itemCompilationContextCreator())
    : this.itemCompilationContextCreator = itemCompilationContextCreator;

  /// Returns [:true:] if this enqueuer is the resolution enqueuer.
  bool get isResolutionQueue => false;

  /// Returns [:true:] if [member] has been processed by this enqueuer.
  bool isProcessed(Element member);

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [element] must be a declaration element.
   */
  void addToWorkList(Element element) {
    assert(invariant(element, element.isDeclaration));
    if (element.isForeign(compiler)) return;

    if (element.isForwardingConstructor) {
      addToWorkList(element.targetConstructor);
      return;
    }

    internalAddToWorkList(element);
  }

  /**
   * Adds [element] to the work list if it has not already been processed.
   */
  void internalAddToWorkList(Element element);

  void registerInstantiatedType(InterfaceType type, TreeElements elements) {
    ClassElement cls = type.element;
    elements.registerDependency(cls);
    cls.ensureResolved(compiler);
    universe.instantiatedTypes.add(type);
    if (universe.instantiatedClasses.contains(cls)) return;
    if (!cls.isAbstract(compiler)) {
      universe.instantiatedClasses.add(cls);
    }
    onRegisterInstantiatedClass(cls);
    // We only tell the backend once that [cls] was instantiated, so
    // any additional dependencies must be treated as global
    // dependencies.
    compiler.backend.registerInstantiatedClass(
        cls, this, compiler.globalDependencies);
  }

  void registerInstantiatedClass(ClassElement cls, TreeElements elements) {
    cls.ensureResolved(compiler);
    registerInstantiatedType(cls.rawType, elements);
  }

  void registerTypeLiteral(Element element, TreeElements elements) {
    registerInstantiatedClass(compiler.typeClass, elements);
    compiler.backend.registerTypeLiteral(elements);
    if (compiler.mirrorsEnabled) {
      // In order to use reflectClass, we need to find the constructor.
      registerInstantiatedClass(element, elements);
    }
  }

  bool checkNoEnqueuedInvokedInstanceMethods() {
    task.measure(() {
      // Run through the classes and see if we need to compile methods.
      for (ClassElement classElement in universe.instantiatedClasses) {
        for (ClassElement currentClass = classElement;
             currentClass != null;
             currentClass = currentClass.superclass) {
          processInstantiatedClass(currentClass);
        }
      }
    });
    return true;
  }

  void processInstantiatedClass(ClassElement cls) {
    cls.implementation.forEachMember(processInstantiatedClassMember);
  }

  /**
   * Documentation wanted -- johnniwinther
   */
  void processInstantiatedClassMember(ClassElement cls, Element member) {
    assert(invariant(member, member.isDeclaration));
    if (isProcessed(member)) return;
    if (!member.isInstanceMember()) return;

    String memberName = member.name.slowToString();

    if (member.kind == ElementKind.FIELD) {
      // The obvious thing to test here would be "member.isNative()",
      // however, that only works after metadata has been parsed/analyzed,
      // and that may not have happened yet.
      // So instead we use the enclosing class, which we know have had
      // its metadata parsed and analyzed.
      // Note: this assumes that there are no non-native fields on native
      // classes, which may not be the case when a native class is subclassed.
      if (cls.isNative()) {
        compiler.world.registerUsedElement(member);
        nativeEnqueuer.handleFieldAnnotations(member);
        if (universe.hasInvokedGetter(member, compiler) ||
            universe.hasInvocation(member, compiler)) {
          nativeEnqueuer.registerFieldLoad(member);
          // In handleUnseenSelector we can't tell if the field is loaded or
          // stored.  We need the basic algorithm to be Church-Rosser, since the
          // resolution 'reduction' order is different to the codegen order. So
          // register that the field is also stored.  In other words: if we
          // don't register the store here during resolution, the store could be
          // registered during codegen on the handleUnseenSelector path, and
          // cause the set of codegen elements to include unresolved elements.
          nativeEnqueuer.registerFieldStore(member);
          addToWorkList(member);
          return;
        }
        if (universe.hasInvokedSetter(member, compiler)) {
          nativeEnqueuer.registerFieldStore(member);
          // See comment after registerFieldLoad above.
          nativeEnqueuer.registerFieldLoad(member);
          addToWorkList(member);
          return;
        }
        // Native fields need to go into instanceMembersByName as they
        // are virtual instantiation points and escape points.
      } else {
        // All field initializers must be resolved as they could
        // have an observable side-effect (and cannot be tree-shaken
        // away).
        addToWorkList(member);
        return;
      }
    } else if (member.kind == ElementKind.FUNCTION) {
      if (member.name == Compiler.NO_SUCH_METHOD) {
        enableNoSuchMethod(member);
      }
      // If there is a property access with the same name as a method we
      // need to emit the method.
      if (universe.hasInvokedGetter(member, compiler)) {
        // We will emit a closure, so make sure the bound closure class is
        // generated.
        registerInstantiatedClass(compiler.boundClosureClass,
                                  // Precise dependency is not important here.
                                  compiler.globalDependencies);
        return addToWorkList(member);
      }
      // Store the member in [instanceFunctionsByName] to catch
      // getters on the function.
      Link<Element> members = instanceFunctionsByName.putIfAbsent(
          memberName, () => const Link<Element>());
      instanceFunctionsByName[memberName] = members.prepend(member);
      if (universe.hasInvocation(member, compiler)) {
        return addToWorkList(member);
      }
    } else if (member.kind == ElementKind.GETTER) {
      if (universe.hasInvokedGetter(member, compiler)) {
        return addToWorkList(member);
      }
      // We don't know what selectors the returned closure accepts. If
      // the set contains any selector we have to assume that it matches.
      if (universe.hasInvocation(member, compiler)) {
        return addToWorkList(member);
      }
    } else if (member.kind == ElementKind.SETTER) {
      if (universe.hasInvokedSetter(member, compiler)) {
        return addToWorkList(member);
      }
    }

    // The element is not yet used. Add it to the list of instance
    // members to still be processed.
    Link<Element> members = instanceMembersByName.putIfAbsent(
        memberName, () => const Link<Element>());
    instanceMembersByName[memberName] = members.prepend(member);
  }

  void enableNoSuchMethod(Element element) {}

  void onRegisterInstantiatedClass(ClassElement cls) {
    task.measure(() {
      // The class must be resolved to compute the set of all
      // supertypes.
      cls.ensureResolved(compiler);

      void processClass(ClassElement cls) {
        if (seenClasses.contains(cls)) return;

        seenClasses.add(cls);
        cls.ensureResolved(compiler);
        cls.implementation.forEachMember(processInstantiatedClassMember);
        if (isResolutionQueue) {
          compiler.resolver.checkClass(cls);
        }
      }
      processClass(cls);
      for (Link<DartType> supertypes = cls.allSupertypes;
           !supertypes.isEmpty; supertypes = supertypes.tail) {
        processClass(supertypes.head.element);
      }
    });
  }

  void registerNewSelector(SourceString name,
                           Selector selector,
                           Map<SourceString, Set<Selector>> selectorsMap) {
    if (name != selector.name) {
      String message = "$name != ${selector.name} (${selector.kind})";
      compiler.internalError("Wrong selector name: $message.");
    }
    Set<Selector> selectors =
        selectorsMap.putIfAbsent(name, () => new Set<Selector>());
    if (!selectors.contains(selector)) {
      selectors.add(selector);
      handleUnseenSelector(name, selector);
    }
  }

  void registerInvocation(SourceString methodName, Selector selector) {
    task.measure(() {
      registerNewSelector(methodName, selector, universe.invokedNames);
    });
  }

  void registerInvokedGetter(SourceString getterName, Selector selector) {
    task.measure(() {
      registerNewSelector(getterName, selector, universe.invokedGetters);
    });
  }

  void registerInvokedSetter(SourceString setterName, Selector selector) {
    task.measure(() {
      registerNewSelector(setterName, selector, universe.invokedSetters);
    });
  }

  /// Called when [:const Symbol(name):] is seen.
  void registerConstSymbol(String name, TreeElements elements) {
    // If dart:mirrors is loaded, a const symbol may be used to call a
    // static/top-level method or accessor, instantiate a class, call
    // an instance method or accessor with the given name.
    if (!compiler.mirrorsEnabled) return;

    task.ensureAllElementsByName();

    for (var link = task.allElementsByName[name];
         link != null && !link.isEmpty;
         link = link.tail) {
      pretendElementWasUsed(link.head, elements);
    }
  }

  void pretendElementWasUsed(Element element, TreeElements elements) {
    if (Elements.isUnresolved(element)) {
      // Ignore.
    } else if (element.isSynthesized
               && element.getLibrary().isPlatformLibrary) {
      // TODO(ahe): Work-around for http://dartbug.com/11205.
    } else if (element.isConstructor()) {
      ClassElement cls = element.declaration.getEnclosingClass();
      registerInstantiatedType(cls.rawType, elements);
      registerStaticUse(element.declaration);
    } else if (element.impliesType()) {
      // Don't enqueue classes, typedefs, and type variables.
    } else if (Elements.isStaticOrTopLevel(element)) {
      registerStaticUse(element.declaration);
    } else if (element.isInstanceMember()) {
      if (element.isFunction()) {
        int arity =
            element.asFunctionElement().requiredParameterCount(compiler);
        Selector selector =
            new Selector.call(element.name, element.getLibrary(), arity);
        registerInvocation(element.name, selector);
      } else if (element.isSetter()) {
        Selector selector =
            new Selector.setter(element.name, element.getLibrary());
        registerInvokedSetter(element.name, selector);
      } else if (element.isGetter()) {
        Selector selector =
            new Selector.getter(element.name, element.getLibrary());
        registerInvokedGetter(element.name, selector);
      } else if (element.isField()) {
        Selector selector =
            new Selector.setter(element.name, element.getLibrary());
        registerInvokedSetter(element.name, selector);
        selector = new Selector.getter(element.name, element.getLibrary());
        registerInvokedGetter(element.name, selector);
      }
    }
  }

  /// Called when [:new Symbol(...):] is seen.
  void registerNewSymbol(TreeElements elements) {
  }

  void enqueueEverything() {
    if (hasEnqueuedEverything) return;
    compiler.log('Enqueuing everything');
    task.ensureAllElementsByName();
    for (Link link in task.allElementsByName.values) {
      for (Element element in link) {
        pretendElementWasUsed(element, compiler.globalDependencies);
      }
    }
    hasEnqueuedEverything = true;
  }

  processLink(Map<String, Link<Element>> map,
              SourceString n,
              bool f(Element e)) {
    String memberName = n.slowToString();
    Link<Element> members = map[memberName];
    if (members != null) {
      LinkBuilder<Element> remaining = new LinkBuilder<Element>();
      for (; !members.isEmpty; members = members.tail) {
        if (!f(members.head)) remaining.addLast(members.head);
      }
      map[memberName] = remaining.toLink();
    }
  }

  processInstanceMembers(SourceString n, bool f(Element e)) {
    processLink(instanceMembersByName, n, f);
  }

  processInstanceFunctions(SourceString n, bool f(Element e)) {
    processLink(instanceFunctionsByName, n, f);
  }

  void handleUnseenSelector(SourceString methodName, Selector selector) {
    processInstanceMembers(methodName, (Element member) {
      if (selector.appliesUnnamed(member, compiler)) {
        if (member.isField() && member.getEnclosingClass().isNative()) {
          if (selector.isGetter() || selector.isCall()) {
            nativeEnqueuer.registerFieldLoad(member);
            // We have to also handle storing to the field because we only get
            // one look at each member and there might be a store we have not
            // seen yet.
            // TODO(sra): Process fields for storing separately.
            nativeEnqueuer.registerFieldStore(member);
          } else {
            assert(selector.isSetter());
            nativeEnqueuer.registerFieldStore(member);
            // We have to also handle loading from the field because we only get
            // one look at each member and there might be a load we have not
            // seen yet.
            // TODO(sra): Process fields for storing separately.
            nativeEnqueuer.registerFieldLoad(member);
          }
        }
        addToWorkList(member);
        return true;
      }
      return false;
    });
    if (selector.isGetter()) {
      processInstanceFunctions(methodName, (Element member) {
        if (selector.appliesUnnamed(member, compiler)) {
          // We will emit a closure, so make sure the bound closure class is
          // generated.
          registerInstantiatedClass(compiler.boundClosureClass,
                                    // Precise dependency is not important here.
                                    compiler.globalDependencies);
          return true;
        }
        return false;
      });
    }
  }

  /**
   * Documentation wanted -- johnniwinther
   *
   * Invariant: [element] must be a declaration element.
   */
  void registerStaticUse(Element element) {
    if (element == null) return;
    assert(invariant(element, element.isDeclaration));
    addToWorkList(element);
    compiler.backend.registerStaticUse(element, this);
  }

  void registerGetOfStaticFunction(FunctionElement element) {
    registerStaticUse(element);
    registerInstantiatedClass(compiler.closureClass,
                              compiler.globalDependencies);
    universe.staticFunctionsNeedingGetter.add(element);
  }

  void registerDynamicInvocation(SourceString methodName, Selector selector) {
    assert(selector != null);
    registerInvocation(methodName, selector);
  }

  void registerDynamicInvocationOf(Element element, Selector selector) {
    assert(selector.isCall()
           || selector.isOperator()
           || selector.isIndex()
           || selector.isIndexSet());
    if (element.isFunction() || element.isGetter()) {
      addToWorkList(element);
    } else if (element.isAbstractField()) {
      AbstractFieldElement field = element;
      // Since the invocation is a dynamic call on a getter, we only
      // need to schedule the getter on the work list.
      addToWorkList(field.getter);
    } else {
      assert(element.isField());
    }
    // We also need to add the selector to the invoked names map,
    // because the emitter uses that map to generate parameter stubs.
    Set<Selector> selectors = universe.invokedNames.putIfAbsent(
        element.name, () => new Set<Selector>());
    selectors.add(selector);
  }

  void registerSelectorUse(Selector selector) {
    if (selector.isGetter()) {
      registerInvokedGetter(selector.name, selector);
    } else if (selector.isSetter()) {
      registerInvokedSetter(selector.name, selector);
    } else {
      registerInvocation(selector.name, selector);
    }
  }

  void registerDynamicGetter(SourceString methodName, Selector selector) {
    registerInvokedGetter(methodName, selector);
  }

  void registerDynamicSetter(SourceString methodName, Selector selector) {
    registerInvokedSetter(methodName, selector);
  }

  void registerFieldGetter(Element element) {
    universe.fieldGetters.add(element);
  }

  void registerFieldSetter(Element element) {
    universe.fieldSetters.add(element);
  }

  void registerIsCheck(DartType type, TreeElements elements) {
    // Even in checked mode, type annotations for return type and argument
    // types do not imply type checks, so there should never be a check
    // against the type variable of a typedef.
    assert(type.kind != TypeKind.TYPE_VARIABLE ||
           !type.element.enclosingElement.isTypedef());
    universe.isChecks.add(type);
    compiler.backend.registerIsCheck(type, this, elements);
  }

  /**
   * If a factory constructor is used with type arguments, we lose track
   * which arguments could be used to create instances of classes that use their
   * type variables as expressions, so we have to remember if we saw such a use.
   */
  void registerFactoryWithTypeArguments(TreeElements elements) {
    universe.usingFactoryWithTypeArguments = true;
  }

  void registerAsCheck(DartType type, TreeElements elements) {
    registerIsCheck(type, elements);
    compiler.backend.registerAsCheck(type, elements);
  }

  void forEach(f(WorkItem work));

  void forEachPostProcessTask(f(PostProcessTask work)) {}

  void logSummary(log(message)) {
    _logSpecificSummary(log);
    nativeEnqueuer.logSummary(log);
  }

  /// Log summary specific to the concrete enqueuer.
  void _logSpecificSummary(log(message));

  String toString() => 'Enqueuer($name)';
}

/// [Enqueuer] which is specific to resolution.
class ResolutionEnqueuer extends Enqueuer {
  /**
   * Map from declaration elements to the [TreeElements] object holding the
   * resolution mapping for the element implementation.
   *
   * Invariant: Key elements are declaration elements.
   */
  final Map<Element, TreeElements> resolvedElements;

  final Queue<ResolutionWorkItem> queue;

  /**
   * A post-processing queue for the resolution phase which is processed
   * immediately after the resolution queue has been closed.
   */
  final Queue<PostProcessTask> postQueue;

  ResolutionEnqueuer(Compiler compiler,
                     ItemCompilationContext itemCompilationContextCreator())
      : super('resolution enqueuer', compiler, itemCompilationContextCreator),
        resolvedElements = new Map<Element, TreeElements>(),
        queue = new Queue<ResolutionWorkItem>(),
        postQueue = new Queue<PostProcessTask>();

  bool get isResolutionQueue => true;

  bool isProcessed(Element member) => resolvedElements.containsKey(member);

  TreeElements getCachedElements(Element element) {
    // TODO(ngeoffray): Get rid of this check.
    if (element.enclosingElement.isClosure()) {
      closureMapping.ClosureClassElement cls = element.enclosingElement;
      element = cls.methodElement;
    } else if (element.isGenerativeConstructorBody()) {
      ConstructorBodyElement body = element;
      element = body.constructor;
    }
    Element owner = element.getOutermostEnclosingMemberOrTopLevel();
    if (owner == null) {
      owner = element;
    }
    return resolvedElements[owner.declaration];
  }

  void internalAddToWorkList(Element element) {
    if (getCachedElements(element) != null) return;
    if (queueIsClosed) {
      throw new SpannableAssertionFailure(element,
                                          "Resolution work list is closed.");
    }
    compiler.world.registerUsedElement(element);

    queue.add(new ResolutionWorkItem(element, itemCompilationContextCreator()));

    // Enable isolate support if we start using something from the
    // isolate library, or timers for the async library.
    LibraryElement library = element.getLibrary();
    if (!compiler.hasIsolateSupport()) {
      String uri = library.canonicalUri.toString();
      if (uri == 'dart:isolate') {
        enableIsolateSupport(library);
      } else if (uri == 'dart:async') {
        ClassElement cls = element.getEnclosingClass();
        if (cls != null && cls.name == const SourceString('Timer')) {
          // The [:Timer:] class uses the event queue of the isolate
          // library, so we make sure that event queue is generated.
          enableIsolateSupport(library);
        }
      }
    }

    if (element.isGetter() && element.name == Compiler.RUNTIME_TYPE) {
      // Enable runtime type support if we discover a getter called runtimeType.
      // We have to enable runtime type before hitting the codegen, so
      // that constructors know whether they need to generate code for
      // runtime type.
      compiler.enabledRuntimeType = true;
      // TODO(ahe): Record precise dependency here.
      compiler.backend.registerRuntimeType(compiler.globalDependencies);
    } else if (element == compiler.functionApplyMethod) {
      compiler.enabledFunctionApply = true;
    } else if (element == compiler.invokeOnMethod) {
      compiler.enabledInvokeOn = true;
    }

    nativeEnqueuer.registerElement(element);
  }

  void enableIsolateSupport(LibraryElement element) {
    compiler.isolateLibrary = element.patch;
    var startRootIsolate =
        compiler.isolateHelperLibrary.find(Compiler.START_ROOT_ISOLATE);
    addToWorkList(startRootIsolate);
    compiler.globalDependencies.registerDependency(startRootIsolate);
    addToWorkList(compiler.isolateHelperLibrary.find(
        const SourceString('_currentIsolate')));
    addToWorkList(compiler.isolateHelperLibrary.find(
        const SourceString('_callInIsolate')));
  }

  void enableNoSuchMethod(Element element) {
    if (compiler.enabledNoSuchMethod) return;
    if (compiler.backend.isDefaultNoSuchMethodImplementation(element)) return;

    Selector selector = compiler.noSuchMethodSelector;
    compiler.enabledNoSuchMethod = true;
    registerInvocation(Compiler.NO_SUCH_METHOD, selector);

    compiler.createInvocationMirrorElement =
        compiler.findHelper(Compiler.CREATE_INVOCATION_MIRROR);
    addToWorkList(compiler.createInvocationMirrorElement);
  }

  void forEach(f(WorkItem work)) {
    while (!queue.isEmpty) {
      // TODO(johnniwinther): Find an optimal process order for resolution.
      f(queue.removeLast());
    }
  }

  /**
   * Adds an action to the post-processing queue.
   *
   * The action is performed as part of the post-processing immediately after
   * the resolution queue has been closed. As a consequence, [action] must not
   * add elements to the resolution queue.
   */
  void addPostProcessAction(Element element, PostProcessAction action) {
    if (queueIsClosed) {
      throw new SpannableAssertionFailure(element,
                                          "Resolution work list is closed.");
    }
    postQueue.add(new PostProcessTask(element, action));
  }

  void forEachPostProcessTask(f(PostProcessTask work)) {
    while (!postQueue.isEmpty) {
      f(postQueue.removeFirst());
    }
  }

  void registerJsCall(Send node, ResolverVisitor resolver) {
    nativeEnqueuer.registerJsCall(node, resolver);
  }

  void _logSpecificSummary(log(message)) {
    log('Resolved ${resolvedElements.length} elements.');
  }
}

/// [Enqueuer] which is specific to code generation.
class CodegenEnqueuer extends Enqueuer {
  final Queue<CodegenWorkItem> queue;
  final Map<Element, js.Expression> generatedCode =
      new Map<Element, js.Expression>();

  CodegenEnqueuer(Compiler compiler,
                  ItemCompilationContext itemCompilationContextCreator())
      : super('codegen enqueuer', compiler, itemCompilationContextCreator),
        queue = new Queue<CodegenWorkItem>();

  bool isProcessed(Element member) =>
      member.isAbstract(compiler) || generatedCode.containsKey(member);

  void internalAddToWorkList(Element element) {
    // Codegen inlines field initializers, so it does not need to add
    // individual fields in the work list.
    if (element.isField() && element.isInstanceMember()) return;

    if (queueIsClosed) {
      throw new SpannableAssertionFailure(element,
                                          "Codegen work list is closed.");
    }
    CodegenWorkItem workItem = new CodegenWorkItem(
        element, itemCompilationContextCreator());
    queue.add(workItem);
  }

  void forEach(f(WorkItem work)) {
    while(!queue.isEmpty) {
      // TODO(johnniwinther): Find an optimal process order for codegen.
      f(queue.removeLast());
    }
  }

  void _logSpecificSummary(log(message)) {
    log('Compiled ${generatedCode.length} methods.');
  }
}
