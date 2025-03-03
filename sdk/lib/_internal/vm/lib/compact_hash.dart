// Copyright (c) 2015, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// part of "collection_patch.dart";

// Hash table with open addressing that separates the index from keys/values.

// This function takes care of rehashing of the linked hashmaps in [objects]. We
// do this eagerly after snapshot deserialization.
@pragma("vm:entry-point", "call")
void _rehashObjects(List objects) {
  final int length = objects.length;
  for (int i = 0; i < length; ++i) {
    objects[i]._regenerateIndex();
  }
}

abstract class _HashFieldBase {
  // Each occupied entry in _index is a fixed-size integer that encodes a pair:
  //   [ hash pattern for key | index of entry in _data ]
  // The hash pattern is based on hashCode, but is guaranteed to be non-zero.
  // The length of _index is always a power of two, and there is always at
  // least one unoccupied entry.
  // NOTE: When maps are deserialized, their _index and _hashMask is regenerated
  // eagerly by _regenerateIndex.
  Uint32List _index = _uninitializedIndex;

  // Cached in-place mask for the hash pattern component.
  int _hashMask = _HashBase._UNINITIALIZED_HASH_MASK;

  // Fixed-length list of keys (set) or key/value at even/odd indices (map).
  //
  // Can be either a mutable or immutable list.
  List _data = _uninitializedData;

  // Length of _data that is used (i.e., keys + values for a map).
  int _usedData = 0;

  // Number of deleted keys.
  int _deletedKeys = 0;

  // Note: All fields are initialized in a single constructor so that the VM
  // recognizes they cannot hold null values. This makes a big (20%) performance
  // difference on some operations.
  _HashFieldBase(int dataSize);
}

// Base class for VM-internal classes; keep in sync with _HashFieldBase.
abstract class _HashVMBase {
  @pragma("vm:recognized", "other")
  @pragma("vm:exact-result-type", "dart:typed_data#_Uint32List")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_getIndex")
  external Uint32List get _index;
  @pragma("vm:recognized", "other")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_setIndex")
  external void set _index(Uint32List value);

  @pragma("vm:recognized", "other")
  @pragma("vm:exact-result-type", "dart:core#_Smi")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_getHashMask")
  external int get _hashMask;
  @pragma("vm:recognized", "other")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_setHashMask")
  external void set _hashMask(int value);

  @pragma("vm:recognized", "other")
  @pragma("vm:exact-result-type", "dart:core#_List")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_getData")
  external List get _data;
  @pragma("vm:recognized", "other")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_setData")
  external void set _data(List value);

  @pragma("vm:recognized", "other")
  @pragma("vm:exact-result-type", "dart:core#_Smi")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_getUsedData")
  external int get _usedData;
  @pragma("vm:recognized", "other")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_setUsedData")
  external void set _usedData(int value);

  @pragma("vm:recognized", "other")
  @pragma("vm:exact-result-type", "dart:core#_Smi")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_getDeletedKeys")
  external int get _deletedKeys;
  @pragma("vm:recognized", "other")
  @pragma("vm:prefer-inline")
  @pragma("vm:external-name", "LinkedHashBase_setDeletedKeys")
  external void set _deletedKeys(int value);
}

// Base class for VM-internal classes; keep in sync with _HashFieldBase.
abstract class _HashVMImmutableBase extends _HashVMBase {
  // The data is an immutable list rather than a mutable list.
  @pragma("vm:recognized", "other")
  @pragma("vm:exact-result-type", "dart:core#_ImmutableList")
  @pragma("vm:prefer-inline")
  List get _data native "ImmutableLinkedHashBase_getData";

  // The index is nullable rather than not nullable.
  @pragma("vm:recognized", "other")
  @pragma("vm:prefer-inline")
  Uint32List? get _indexNullable native "ImmutableLinkedHashBase_getIndex";
  Uint32List get _index => _indexNullable!;

  // Uses store-release atomic.
  @pragma("vm:recognized", "other")
  @pragma("vm:prefer-inline")
  void set _index(Uint32List value)
      native "ImmutableLinkedHashBase_setIndexStoreRelease";
}

// This mixin can be applied to _HashFieldBase or _HashVMBase (for
// normal and VM-internalized classes, respectiveley), which provide the
// actual fields/accessors that this mixin assumes.
// TODO(koda): Consider moving field comments to _HashFieldBase.
abstract class _HashBase implements _HashVMBase {
  // The number of bits used for each component is determined by table size.
  // If initialized, the length of _index is (at least) twice the number of
  // entries in _data, and both are doubled when _data is full. Thus, _index
  // will have a max load factor of 1/2, which enables one more bit to be used
  // for the hash.
  // TODO(koda): Consider growing _data by factor sqrt(2), twice as often.
  static const int _INITIAL_INDEX_BITS = 2;
  static const int _INITIAL_INDEX_SIZE = 1 << (_INITIAL_INDEX_BITS + 1);
  static const int _UNINITIALIZED_INDEX_SIZE = 1;
  static const int _UNINITIALIZED_HASH_MASK = 0;

  // Unused and deleted entries are marked by 0 and 1, respectively.
  static const int _UNUSED_PAIR = 0;
  static const int _DELETED_PAIR = 1;

  // On 32-bit, the top bits are wasted to avoid Mint allocation.
  // TODO(koda): Reclaim the bits by making the compiler treat hash patterns
  // as unsigned words.
  // Keep consistent with IndexSizeToHashMask in runtime/vm/object.h.
  static int _indexSizeToHashMask(int indexSize) {
    assert(indexSize >= _INITIAL_INDEX_SIZE ||
        indexSize == _UNINITIALIZED_INDEX_SIZE);
    if (indexSize == _UNINITIALIZED_INDEX_SIZE) {
      return _UNINITIALIZED_HASH_MASK;
    }
    int indexBits = indexSize.bitLength - 2;
    return internal.has63BitSmis
        ? (1 << (32 - indexBits)) - 1
        : (1 << (30 - indexBits)) - 1;
  }

  static int _hashPattern(int fullHash, int hashMask, int size) {
    final int maskedHash = fullHash & hashMask;
    // TODO(koda): Consider keeping bit length and use left shift.
    return (maskedHash == 0) ? (size >> 1) : maskedHash * (size >> 1);
  }

  // Linear probing.
  static int _firstProbe(int fullHash, int sizeMask) {
    final int i = fullHash & sizeMask;
    // Light, fast shuffle to mitigate bad hashCode (e.g., sequential).
    return ((i << 1) + i) & sizeMask;
  }

  static int _nextProbe(int i, int sizeMask) => (i + 1) & sizeMask;

  // A self-loop is used to mark a deleted key or value.
  static bool _isDeleted(List data, Object? keyOrValue) =>
      identical(keyOrValue, data);
  static void _setDeletedAt(List data, int d) {
    data[d] = data;
  }

  // Concurrent modification detection relies on this checksum monotonically
  // increasing between reallocations of _data.
  int get _checkSum => _usedData + _deletedKeys;
  bool _isModifiedSince(List oldData, int oldCheckSum) =>
      !identical(_data, oldData) || (_checkSum != oldCheckSum);

  int get length;

  // If this collection has never had an insertion, and [other] is the same
  // representation and has had no deletions, then adding the entries of [other]
  // will end up building the same [_data] and [_index]. We can do this more
  // efficiently by copying the Lists directly.
  //
  // Precondition: [this] and [other] must use the same hashcode and equality.
  bool _quickCopy(_HashBase other) {
    if (!identical(_index, _uninitializedIndex)) return false;
    if (other._usedData == 0) return true; // [other] is empty, nothing to copy.
    if (other._deletedKeys != 0) return false;

    assert(!identical(other._index, _uninitializedIndex));
    assert(!identical(other._data, _uninitializedData));
    _index = Uint32List.fromList(other._index);
    _hashMask = other._hashMask;
    _data = List.of(other._data, growable: false);
    _usedData = other._usedData;
    _deletedKeys = other._deletedKeys;
    return true;
  }
}

class _OperatorEqualsAndHashCode {
  int _hashCode(e) => e.hashCode;
  bool _equals(e1, e2) => e1 == e2;
}

class _IdenticalAndIdentityHashCode {
  int _hashCode(e) => identityHashCode(e);
  bool _equals(e1, e2) => identical(e1, e2);
}

class _OperatorEqualsAndCanonicalHashCode {
  static final int cidSymbol = ClassID.getID(#a);

  int _hashCode(e) {
    final int cid = ClassID.getID(e);
    if (cid < ClassID.numPredefinedCids || cid == cidSymbol) {
      return e.hashCode;
    }
    return identityHashCode(e);
  }

  bool _equals(e1, e2) => e1 == e2;
}

final _uninitializedIndex = new Uint32List(_HashBase._UNINITIALIZED_INDEX_SIZE);
// Note: not const. Const arrays are made immutable by having a different class
// than regular arrays that throws on element assignment. We want the data field
// in maps and sets to be monomorphic.
final _uninitializedData = new List.filled(0, null);

// VM-internalized implementation of a default-constructed LinkedHashMap.
@pragma("vm:entry-point")
class _InternalLinkedHashMap<K, V> extends _HashVMBase
    with
        MapMixin<K, V>,
        _LinkedHashMapMixin<K, V>,
        _HashBase,
        _OperatorEqualsAndHashCode
    implements LinkedHashMap<K, V> {
  _InternalLinkedHashMap() {
    _index = _uninitializedIndex;
    _hashMask = _HashBase._UNINITIALIZED_HASH_MASK;
    _data = _uninitializedData;
    _usedData = 0;
    _deletedKeys = 0;
  }

  void addAll(Map<K, V> other) {
    if (other is _InternalLinkedHashMap) {
      final otherBase = other as _InternalLinkedHashMap; // manual promotion.
      // If this map is empty we might be able to block-copy from [other].
      if (isEmpty && _quickCopy(otherBase)) return;
      // TODO(48143): Pre-grow capacity if it will reduce rehashing.
    }
    super.addAll(other);
  }
}

// This is essentially the same class as _InternalLinkedHashMap, but it does
// not permit any modification of map entries from Dart code. We use
// this class for maps constructed from Dart constant maps.
@pragma("vm:entry-point")
class _InternalImmutableLinkedHashMap<K, V> extends _HashVMImmutableBase
    with
        MapMixin<K, V>,
        _LinkedHashMapMixin<K, V>,
        _HashBase,
        _OperatorEqualsAndCanonicalHashCode,
        _UnmodifiableMapMixin<K, V>
    implements LinkedHashMap<K, V> {
  factory _InternalImmutableLinkedHashMap._uninstantiable() {
    throw new UnsupportedError("ImmutableMap can only be allocated by the VM");
  }

  bool containsKey(Object? key) {
    if (_indexNullable == null) {
      _createIndex();
    }
    return super.containsKey(key);
  }

  V? operator [](Object? key) {
    if (_indexNullable == null) {
      _createIndex();
    }
    return super[key];
  }

  void _createIndex() {
    final size = max(_data.length, _HashBase._INITIAL_INDEX_SIZE);
    assert(size == _roundUpToPowerOfTwo(size));
    final newIndex = new Uint32List(size);
    final hashMask = _HashBase._indexSizeToHashMask(size);
    assert(_hashMask == hashMask);

    for (int j = 0; j < _usedData; j += 2) {
      final key = _data[j];
      final value = _data[j + 1];

      final fullHash = _hashCode(key);
      final hashPattern = _HashBase._hashPattern(fullHash, hashMask, size);
      final d =
          _findValueOrInsertPoint(key, fullHash, hashPattern, size, newIndex);
      // We just allocated the index, so we should not find this key in it yet.
      assert(d <= 0);

      final i = -d;

      assert(1 <= hashPattern && hashPattern < (1 << 32));
      final index = j >> 1;
      assert((index & hashPattern) == 0);
      newIndex[i] = hashPattern | index;
    }

    // Publish new index, uses store release semantics.
    _index = newIndex;
  }
}

// Implementation is from "Hacker's Delight" by Henry S. Warren, Jr.,
// figure 3-3, page 48, where the function is called clp2.
int _roundUpToPowerOfTwo(int x) {
  x = x - 1;
  x = x | (x >> 1);
  x = x | (x >> 2);
  x = x | (x >> 4);
  x = x | (x >> 8);
  x = x | (x >> 16);
  x = x | (x >> 32);
  return x + 1;
}

abstract class _LinkedHashMapMixin<K, V> implements _HashBase {
  int _hashCode(e);
  bool _equals(e1, e2);
  int get _checkSum;
  bool _isModifiedSince(List oldData, int oldCheckSum);

  int get length => (_usedData >> 1) - _deletedKeys;
  bool get isEmpty => length == 0;
  bool get isNotEmpty => !isEmpty;

  void _rehash() {
    if ((_deletedKeys << 2) > _usedData) {
      // TODO(koda): Consider shrinking.
      // TODO(koda): Consider in-place compaction and more costly CME check.
      _init(_index.length, _hashMask, _data, _usedData);
    } else {
      // TODO(koda): Support 32->64 bit transition (and adjust _hashMask).
      _init(_index.length << 1, _hashMask >> 1, _data, _usedData);
    }
  }

  void clear() {
    if (!isEmpty) {
      _index = _uninitializedIndex;
      _hashMask = _HashBase._UNINITIALIZED_HASH_MASK;
      _data = _uninitializedData;
      _usedData = 0;
      _deletedKeys = 0;
    }
  }

  // Allocate new _index and _data, and optionally copy existing contents.
  void _init(int size, int hashMask, List? oldData, int oldUsed) {
    if (size < _HashBase._INITIAL_INDEX_SIZE) {
      size = _HashBase._INITIAL_INDEX_SIZE;
      hashMask = _HashBase._indexSizeToHashMask(size);
    }
    assert(size & (size - 1) == 0);
    assert(_HashBase._UNUSED_PAIR == 0);
    _index = new Uint32List(size);
    _hashMask = hashMask;
    _data = new List.filled(size, null);
    _usedData = 0;
    _deletedKeys = 0;
    if (oldData != null) {
      for (int i = 0; i < oldUsed; i += 2) {
        var key = oldData[i];
        if (!_HashBase._isDeleted(oldData, key)) {
          // TODO(koda): While there are enough hash bits, avoid hashCode calls.
          this[key] = oldData[i + 1];
        }
      }
    }
  }

  // This method is called by [_rehashObjects] (see above).
  void _regenerateIndex() {
    _index =
        _data.length == 0 ? _uninitializedIndex : new Uint32List(_data.length);
    assert(_hashMask == _HashBase._UNINITIALIZED_HASH_MASK);
    _hashMask = _HashBase._indexSizeToHashMask(_index.length);
    final int tmpUsed = _usedData;
    _usedData = 0;
    _deletedKeys = 0;
    for (int i = 0; i < tmpUsed; i += 2) {
      final key = _data[i];
      if (!_HashBase._isDeleted(_data, key)) {
        this[key] = _data[i + 1];
      }
    }
  }

  void _insert(K key, V value, int hashPattern, int i) {
    if (_usedData == _data.length) {
      _rehash();
      this[key] = value;
    } else {
      assert(1 <= hashPattern && hashPattern < (1 << 32));
      final int index = _usedData >> 1;
      assert((index & hashPattern) == 0);
      _index[i] = hashPattern | index;
      _data[_usedData++] = key;
      _data[_usedData++] = value;
    }
  }

  // If key is present, returns the index of the value in _data, else returns
  // the negated insertion point in index.
  int _findValueOrInsertPoint(
      K key, int fullHash, int hashPattern, int size, Uint32List index) {
    final int sizeMask = size - 1;
    final int maxEntries = size >> 1;
    int i = _HashBase._firstProbe(fullHash, sizeMask);
    int firstDeleted = -1;
    int pair = index[i];
    while (pair != _HashBase._UNUSED_PAIR) {
      if (pair == _HashBase._DELETED_PAIR) {
        if (firstDeleted < 0) {
          firstDeleted = i;
        }
      } else {
        final int entry = hashPattern ^ pair;
        if (entry < maxEntries) {
          final int d = entry << 1;
          if (_equals(key, _data[d])) {
            return d + 1;
          }
        }
      }
      i = _HashBase._nextProbe(i, sizeMask);
      pair = index[i];
    }
    return firstDeleted >= 0 ? -firstDeleted : -i;
  }

  void operator []=(K key, V value) {
    final int size = _index.length;
    final int fullHash = _hashCode(key);
    final int hashPattern = _HashBase._hashPattern(fullHash, _hashMask, size);
    final int d =
        _findValueOrInsertPoint(key, fullHash, hashPattern, size, _index);
    if (d > 0) {
      _data[d] = value;
    } else {
      final int i = -d;
      _insert(key, value, hashPattern, i);
    }
  }

  V putIfAbsent(K key, V ifAbsent()) {
    final int size = _index.length;
    final int fullHash = _hashCode(key);
    final int hashPattern = _HashBase._hashPattern(fullHash, _hashMask, size);
    final int d =
        _findValueOrInsertPoint(key, fullHash, hashPattern, size, _index);
    if (d > 0) {
      return _data[d];
    }
    // 'ifAbsent' is allowed to modify the map.
    List oldData = _data;
    int oldCheckSum = _checkSum;
    V value = ifAbsent();
    if (_isModifiedSince(oldData, oldCheckSum)) {
      this[key] = value;
    } else {
      final int i = -d;
      _insert(key, value, hashPattern, i);
    }
    return value;
  }

  V? remove(Object? key) {
    final int size = _index.length;
    final int sizeMask = size - 1;
    final int maxEntries = size >> 1;
    final int fullHash = _hashCode(key);
    final int hashPattern = _HashBase._hashPattern(fullHash, _hashMask, size);
    int i = _HashBase._firstProbe(fullHash, sizeMask);
    int pair = _index[i];
    while (pair != _HashBase._UNUSED_PAIR) {
      if (pair != _HashBase._DELETED_PAIR) {
        final int entry = hashPattern ^ pair;
        if (entry < maxEntries) {
          final int d = entry << 1;
          if (_equals(key, _data[d])) {
            _index[i] = _HashBase._DELETED_PAIR;
            _HashBase._setDeletedAt(_data, d);
            V value = _data[d + 1];
            _HashBase._setDeletedAt(_data, d + 1);
            ++_deletedKeys;
            return value;
          }
        }
      }
      i = _HashBase._nextProbe(i, sizeMask);
      pair = _index[i];
    }
    return null;
  }

  // If key is absent, return _data (which is never a value).
  Object? _getValueOrData(Object? key) {
    final int size = _index.length;
    final int sizeMask = size - 1;
    final int maxEntries = size >> 1;
    final int fullHash = _hashCode(key);
    final int hashPattern = _HashBase._hashPattern(fullHash, _hashMask, size);
    int i = _HashBase._firstProbe(fullHash, sizeMask);
    int pair = _index[i];
    while (pair != _HashBase._UNUSED_PAIR) {
      if (pair != _HashBase._DELETED_PAIR) {
        final int entry = hashPattern ^ pair;
        if (entry < maxEntries) {
          final int d = entry << 1;
          if (_equals(key, _data[d])) {
            return _data[d + 1];
          }
        }
      }
      i = _HashBase._nextProbe(i, sizeMask);
      pair = _index[i];
    }
    return _data;
  }

  bool containsKey(Object? key) => !identical(_data, _getValueOrData(key));

  V? operator [](Object? key) {
    var v = _getValueOrData(key);
    return identical(_data, v) ? null : internal.unsafeCast<V>(v);
  }

  bool containsValue(Object? value) {
    for (var v in values) {
      // Spec. says this should always use "==", also for identity maps, etc.
      if (v == value) {
        return true;
      }
    }
    return false;
  }

  void forEach(void action(K key, V value)) {
    final data = _data;
    final checkSum = _checkSum;
    final len = _usedData;
    for (int offset = 0; offset < len; offset += 2) {
      final current = data[offset];
      if (_HashBase._isDeleted(data, current)) continue;
      final key = internal.unsafeCast<K>(current);
      final value = internal.unsafeCast<V>(data[offset + 1]);
      action(key, value);
      if (_isModifiedSince(data, checkSum)) {
        throw ConcurrentModificationError(this);
      }
    }
  }

  Iterable<K> get keys =>
      new _CompactIterable<K>(this, _data, _usedData, -2, 2);
  Iterable<V> get values =>
      new _CompactIterable<V>(this, _data, _usedData, -1, 2);
}

class _CompactLinkedIdentityHashMap<K, V> extends _HashFieldBase
    with
        MapMixin<K, V>,
        _LinkedHashMapMixin<K, V>,
        _HashBase,
        _IdenticalAndIdentityHashCode
    implements LinkedHashMap<K, V> {
  _CompactLinkedIdentityHashMap() : super(_HashBase._INITIAL_INDEX_SIZE);

  void addAll(Map<K, V> other) {
    if (other is _CompactLinkedIdentityHashMap) {
      final otherBase = other as _CompactLinkedIdentityHashMap;
      // If this map is empty we might be able to block-copy from [other].
      if (isEmpty && _quickCopy(otherBase)) return;
      // TODO(48143): Pre-grow capacity if it will reduce rehashing.
    }
    super.addAll(other);
  }
}

class _CompactLinkedCustomHashMap<K, V> extends _HashFieldBase
    with MapMixin<K, V>, _LinkedHashMapMixin<K, V>, _HashBase
    implements LinkedHashMap<K, V> {
  final _equality;
  final _hasher;
  final _validKey;

  // TODO(koda): Ask gbracha why I cannot have fields _equals/_hashCode.
  int _hashCode(e) => _hasher(e);
  bool _equals(e1, e2) => _equality(e1, e2);

  bool containsKey(Object? o) => _validKey(o) ? super.containsKey(o) : false;
  V? operator [](Object? o) => _validKey(o) ? super[o] : null;
  V? remove(Object? o) => _validKey(o) ? super.remove(o) : null;

  _CompactLinkedCustomHashMap(this._equality, this._hasher, validKey)
      : _validKey = (validKey != null) ? validKey : new _TypeTest<K>().test,
        super(_HashBase._INITIAL_INDEX_SIZE);
}

// Iterates through _data[_offset + _step], _data[_offset + 2*_step], ...
// and checks for concurrent modification.
class _CompactIterable<E> extends Iterable<E> {
  final _HashBase _table;
  final List _data;
  final int _len;
  final int _offset;
  final int _step;

  _CompactIterable(
      this._table, this._data, this._len, this._offset, this._step);

  Iterator<E> get iterator =>
      new _CompactIterator<E>(_table, _data, _len, _offset, _step);

  int get length => _table.length;
  bool get isEmpty => length == 0;
  bool get isNotEmpty => !isEmpty;
}

class _CompactIterator<E> implements Iterator<E> {
  final _HashBase _table;
  final List _data;
  final int _len;
  int _offset;
  final int _step;
  final int _checkSum;
  E? _current;

  _CompactIterator(
      _HashBase table, this._data, this._len, this._offset, this._step)
      : _table = table,
        _checkSum = table._checkSum;

  bool moveNext() {
    if (_table._isModifiedSince(_data, _checkSum)) {
      throw new ConcurrentModificationError(_table);
    }
    do {
      _offset += _step;
    } while (_offset < _len && _HashBase._isDeleted(_data, _data[_offset]));
    if (_offset < _len) {
      _current = internal.unsafeCast<E>(_data[_offset]);
      return true;
    } else {
      _current = null;
      return false;
    }
  }

  E get current => _current as E;
}

abstract class _LinkedHashSetMixin<E> implements _HashBase {
  int _hashCode(e);
  bool _equals(e1, e2);
  int get _checkSum;
  bool _isModifiedSince(List oldData, int oldCheckSum);

  bool get isEmpty => length == 0;
  bool get isNotEmpty => !isEmpty;
  int get length => _usedData - _deletedKeys;

  E get first {
    for (int offset = 0; offset < _usedData; offset++) {
      Object? current = _data[offset];
      if (!_HashBase._isDeleted(_data, current)) {
        return current as E;
      }
    }
    throw IterableElementError.noElement();
  }

  E get last {
    for (int offset = _usedData - 1; offset >= 0; offset--) {
      Object? current = _data[offset];
      if (!_HashBase._isDeleted(_data, current)) {
        return current as E;
      }
    }
    throw IterableElementError.noElement();
  }

  void _rehash() {
    if ((_deletedKeys << 1) > _usedData) {
      _init(_index.length, _hashMask, _data, _usedData);
    } else {
      _init(_index.length << 1, _hashMask >> 1, _data, _usedData);
    }
  }

  void clear() {
    if (!isEmpty) {
      _index = _uninitializedIndex;
      _hashMask = _HashBase._UNINITIALIZED_HASH_MASK;
      _data = _uninitializedData;
      _usedData = 0;
      _deletedKeys = 0;
    }
  }

  void _init(int size, int hashMask, List? oldData, int oldUsed) {
    if (size < _HashBase._INITIAL_INDEX_SIZE) {
      size = _HashBase._INITIAL_INDEX_SIZE;
      hashMask = _HashBase._indexSizeToHashMask(size);
    }
    _index = new Uint32List(size);
    _hashMask = hashMask;
    _data = new List.filled(size >> 1, null);
    _usedData = 0;
    _deletedKeys = 0;
    if (oldData != null) {
      for (int i = 0; i < oldUsed; i += 1) {
        var key = oldData[i];
        if (!_HashBase._isDeleted(oldData, key)) {
          add(key);
        }
      }
    }
  }

  bool add(E key) {
    final int size = _index.length;
    final int sizeMask = size - 1;
    final int maxEntries = size >> 1;
    final int fullHash = _hashCode(key);
    final int hashPattern = _HashBase._hashPattern(fullHash, _hashMask, size);
    int i = _HashBase._firstProbe(fullHash, sizeMask);
    int firstDeleted = -1;
    int pair = _index[i];
    while (pair != _HashBase._UNUSED_PAIR) {
      if (pair == _HashBase._DELETED_PAIR) {
        if (firstDeleted < 0) {
          firstDeleted = i;
        }
      } else {
        final int d = hashPattern ^ pair;
        if (d < maxEntries && _equals(key, _data[d])) {
          return false;
        }
      }
      i = _HashBase._nextProbe(i, sizeMask);
      pair = _index[i];
    }
    if (_usedData == _data.length) {
      _rehash();
      add(key);
    } else {
      final int insertionPoint = (firstDeleted >= 0) ? firstDeleted : i;
      assert(1 <= hashPattern && hashPattern < (1 << 32));
      assert((hashPattern & _usedData) == 0);
      _index[insertionPoint] = hashPattern | _usedData;
      _data[_usedData++] = key;
    }
    return true;
  }

  // If key is absent, return _data (which is never a value).
  Object? _getKeyOrData(Object? key) {
    final int size = _index.length;
    final int sizeMask = size - 1;
    final int maxEntries = size >> 1;
    final int fullHash = _hashCode(key);
    final int hashPattern = _HashBase._hashPattern(fullHash, _hashMask, size);
    int i = _HashBase._firstProbe(fullHash, sizeMask);
    int pair = _index[i];
    while (pair != _HashBase._UNUSED_PAIR) {
      if (pair != _HashBase._DELETED_PAIR) {
        final int d = hashPattern ^ pair;
        if (d < maxEntries && _equals(key, _data[d])) {
          return _data[d]; // Note: Must return the existing key.
        }
      }
      i = _HashBase._nextProbe(i, sizeMask);
      pair = _index[i];
    }
    return _data;
  }

  E? lookup(Object? key) {
    var k = _getKeyOrData(key);
    return identical(_data, k) ? null : internal.unsafeCast<E>(k);
  }

  bool contains(Object? key) => !identical(_data, _getKeyOrData(key));

  bool remove(Object? key) {
    final int size = _index.length;
    final int sizeMask = size - 1;
    final int maxEntries = size >> 1;
    final int fullHash = _hashCode(key);
    final int hashPattern = _HashBase._hashPattern(fullHash, _hashMask, size);
    int i = _HashBase._firstProbe(fullHash, sizeMask);
    int pair = _index[i];
    while (pair != _HashBase._UNUSED_PAIR) {
      if (pair != _HashBase._DELETED_PAIR) {
        final int d = hashPattern ^ pair;
        if (d < maxEntries && _equals(key, _data[d])) {
          _index[i] = _HashBase._DELETED_PAIR;
          _HashBase._setDeletedAt(_data, d);
          ++_deletedKeys;
          return true;
        }
      }
      i = _HashBase._nextProbe(i, sizeMask);
      pair = _index[i];
    }
    return false;
  }

  Iterator<E> get iterator =>
      new _CompactIterator<E>(this, _data, _usedData, -1, 1);

  // This method is called by [_rehashObjects] (see above).
  void _regenerateIndex() {
    final size =
        _roundUpToPowerOfTwo(max(_data.length, _HashBase._INITIAL_INDEX_SIZE));
    _index = _data.length == 0 ? _uninitializedIndex : new Uint32List(size);
    assert(_hashMask == _HashBase._UNINITIALIZED_HASH_MASK);
    _hashMask = _HashBase._indexSizeToHashMask(_index.length);
    _rehash();
  }
}

// Set implementation, analogous to _CompactLinkedHashMap.
@pragma('vm:entry-point')
class _CompactLinkedHashSet<E> extends _HashVMBase
    with
        SetMixin<E>,
        _LinkedHashSetMixin<E>,
        _HashBase,
        _OperatorEqualsAndHashCode
    implements LinkedHashSet<E> {
  _CompactLinkedHashSet() {
    _index = _uninitializedIndex;
    _hashMask = _HashBase._UNINITIALIZED_HASH_MASK;
    _data = _uninitializedData;
    _usedData = 0;
    _deletedKeys = 0;
  }

  Set<R> cast<R>() => Set.castFrom<E, R>(this, newSet: _newEmpty);

  static Set<R> _newEmpty<R>() => new _CompactLinkedHashSet<R>();

  // Returns a set of the same type, although this
  // is not required by the spec. (For instance, always using an identity set
  // would be technically correct, albeit surprising.)
  Set<E> toSet() => new _CompactLinkedHashSet<E>()..addAll(this);

  void addAll(Iterable<E> other) {
    if (other is _CompactLinkedHashSet) {
      final otherBase = other as _CompactLinkedHashSet;
      // If this set is empty we might be able to block-copy from [other].
      if (isEmpty && _quickCopy(otherBase)) return;
      // TODO(48143): Pre-grow capacity if it will reduce rehashing.
    }
    super.addAll(other);
  }
}

@pragma("vm:entry-point")
class _CompactImmutableLinkedHashSet<E> extends _HashVMImmutableBase
    with
        SetMixin<E>,
        _LinkedHashSetMixin<E>,
        _HashBase,
        _OperatorEqualsAndCanonicalHashCode,
        _UnmodifiableSetMixin<E>
    implements LinkedHashSet<E> {
  factory _CompactImmutableLinkedHashSet._uninstantiable() {
    throw new UnsupportedError("ImmutableSet can only be allocated by the VM");
  }

  E? lookup(Object? key) {
    if (_indexNullable == null) {
      _createIndex();
    }
    return super.lookup(key);
  }

  bool contains(Object? key) {
    if (_indexNullable == null) {
      _createIndex();
    }
    return super.contains(key);
  }

  void _createIndex() {
    final size = _roundUpToPowerOfTwo(
        max(_data.length * 2, _HashBase._INITIAL_INDEX_SIZE));
    final index = new Uint32List(size);
    final hashMask = _HashBase._indexSizeToHashMask(size);
    assert(_hashMask == hashMask);

    final sizeMask = size - 1;
    final maxEntries = size >> 1;

    for (int j = 0; j < _usedData; j++) {
      final key = _data[j];

      final fullHash = _hashCode(key);
      final hashPattern = _HashBase._hashPattern(fullHash, hashMask, size);

      int i = _HashBase._firstProbe(fullHash, sizeMask);
      int pair = index[i];
      while (pair != _HashBase._UNUSED_PAIR) {
        assert(pair != _HashBase._DELETED_PAIR);

        final int d = hashPattern ^ pair;
        if (d < maxEntries) {
          // We should not already find an entry in the index.
          assert(!_equals(key, _data[d]));
        }

        i = _HashBase._nextProbe(i, sizeMask);
        pair = index[i];
      }

      final int insertionPoint = i;
      assert(1 <= hashPattern && hashPattern < (1 << 32));
      assert((hashPattern & j) == 0);
      index[insertionPoint] = hashPattern | j;
    }

    // Publish new index, uses store release semantics.
    _index = index;
  }

  Set<R> cast<R>() => Set.castFrom<E, R>(this, newSet: _newEmpty);

  static Set<R> _newEmpty<R>() => new _CompactLinkedHashSet<R>();

  // Returns a mutable set.
  Set<E> toSet() => new _CompactLinkedHashSet<E>()..addAll(this);
}

class _CompactLinkedIdentityHashSet<E> extends _HashFieldBase
    with
        SetMixin<E>,
        _LinkedHashSetMixin<E>,
        _HashBase,
        _IdenticalAndIdentityHashCode
    implements LinkedHashSet<E> {
  _CompactLinkedIdentityHashSet() : super(_HashBase._INITIAL_INDEX_SIZE);

  Set<E> toSet() => new _CompactLinkedIdentityHashSet<E>()..addAll(this);

  static Set<R> _newEmpty<R>() => new _CompactLinkedIdentityHashSet<R>();

  Set<R> cast<R>() => Set.castFrom<E, R>(this, newSet: _newEmpty);

  void addAll(Iterable<E> other) {
    if (other is _CompactLinkedIdentityHashSet) {
      final otherBase = other as _CompactLinkedIdentityHashSet;
      // If this set is empty we might be able to block-copy from [other].
      if (isEmpty && _quickCopy(otherBase)) return;
      // TODO(48143): Pre-grow capacity if it will reduce rehashing.
    }
    super.addAll(other);
  }
}

class _CompactLinkedCustomHashSet<E> extends _HashFieldBase
    with SetMixin<E>, _LinkedHashSetMixin<E>, _HashBase
    implements LinkedHashSet<E> {
  final _equality;
  final _hasher;
  final _validKey;

  int _hashCode(e) => _hasher(e);
  bool _equals(e1, e2) => _equality(e1, e2);

  bool contains(Object? o) => _validKey(o) ? super.contains(o) : false;
  E? lookup(Object? o) => _validKey(o) ? super.lookup(o) : null;
  bool remove(Object? o) => _validKey(o) ? super.remove(o) : false;

  _CompactLinkedCustomHashSet(this._equality, this._hasher, validKey)
      : _validKey = (validKey != null) ? validKey : new _TypeTest<E>().test,
        super(_HashBase._INITIAL_INDEX_SIZE);

  Set<R> cast<R>() => Set.castFrom<E, R>(this);
  Set<E> toSet() =>
      new _CompactLinkedCustomHashSet<E>(_equality, _hasher, _validKey)
        ..addAll(this);
}
