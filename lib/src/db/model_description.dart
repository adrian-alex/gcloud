// Copyright (c) 2014, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

part of gcloud.db;

/// Subclasses of [ModelDescription] describe how to map a dart model object
/// to a Datastore Entity.
///
/// Please see [ModelMetadata] for an example on how to use them.
abstract class ModelDescription {
  static String ID_FIELDNAME = 'id';

  // NOTE: These integer constants are array indices into the state vector.
  // Subclasses may need to take this into account.
  static const int STATE_PROPERTYNAME_TO_FIELDNAME_MAP = 0;
  static const int STATE_FIELDNAME_TO_PROPERTYNAME_MAP = 1;
  static const int STATE_INDEXED_PROPERTIES = 2;
  static const int STATE_UNINDEXED_PROPERTIES = 3;
  static const int STATE_LAST = STATE_UNINDEXED_PROPERTIES;

  final String _kind;
  const ModelDescription(this._kind);

  initialize(ModelDB db) {
    // Compute propertyName -> fieldName mapping.
    var property2FieldName = new HashMap<String, String>();
    var field2PropertyName = new HashMap<String, String>();

    db.propertiesForModel(this).forEach((String fieldName, Property prop) {
      // The default of a datastore property name is the fieldName.
      // It can be overridden with [Property.propertyName].
      String propertyName = prop.propertyName;
      if (propertyName == null) propertyName = fieldName;

      if (fieldName != ModelDescription.ID_FIELDNAME) {
        property2FieldName[propertyName] = fieldName;
        field2PropertyName[fieldName] = propertyName;
      }
    });

    // Compute properties & unindexed properties
    var indexedProperties = new Set<String>();
    var unIndexedProperties = new Set<String>();

    db.propertiesForModel(this).forEach((String fieldName, Property prop) {
      if (fieldName != ModelDescription.ID_FIELDNAME) {
        String propertyName = prop.propertyName;
        if (propertyName == null) propertyName = fieldName;

        if (prop.indexed) {
          indexedProperties.add(propertyName);
        } else {
          unIndexedProperties.add(propertyName);
        }
      }
    });

    // NOTE: This state vector is indexed by the STATE_* integer constants!
    return new List.from([
        property2FieldName,
        field2PropertyName,
        indexedProperties,
        unIndexedProperties,
    ], growable: false);
  }

  bool registerKind(ModelDB db) => true;

  String kindName(ModelDB db) => _kind;

  datastore.Entity encodeModel(ModelDB db, Model model) {
    List stateVector =  db.modelDescriptionState(this);
    var key = db.toDatastoreKey(model.key);

    var properties = {};
    var unIndexedProperties = stateVector[STATE_UNINDEXED_PROPERTIES];
    var mirror = mirrors.reflect(model);

    db.propertiesForModel(this).forEach((String fieldName, Property prop) {
      _encodeProperty(db, model, mirror, properties, fieldName, prop);
    });

    return new datastore.Entity(
        key, properties, unIndexedProperties: unIndexedProperties);
  }

  _encodeProperty(ModelDB db, Model model, mirrors.InstanceMirror mirror,
                  Map properties, String fieldName, Property prop) {
    String propertyName = prop.propertyName;
    if (propertyName == null) propertyName = fieldName;

    if (fieldName != ModelDescription.ID_FIELDNAME) {
      var value = mirror.getField(
          mirrors.MirrorSystem.getSymbol(fieldName)).reflectee;
      if (!prop.validate(db, value)) {
        throw new StateError('Property validation failed for '
            'property $fieldName while trying to serialize entity of kind '
            '${model.runtimeType}. ');
      }
      properties[propertyName] = prop.encodeValue(db, value);
    }
  }

  Model decodeEntity(ModelDB db, Key key, datastore.Entity entity) {
    if (entity == null) return null;

    // NOTE: this assumes a default constructor for the model classes!
    var classMirror = db.modelClass(this);
    var mirror = classMirror.newInstance(const Symbol(''), []);

    // Set the id and the parent key
    mirror.reflectee.id = key.id;
    mirror.reflectee.parentKey = key.parent;

    db.propertiesForModel(this).forEach((String fieldName, Property prop) {
      _decodeProperty(db, entity, mirror, fieldName, prop);
    });
    return mirror.reflectee;
  }

  _decodeProperty(ModelDB db, datastore.Entity entity,
                  mirrors.InstanceMirror mirror, String fieldName,
                  Property prop) {
    String propertyName = fieldNameToPropertyName(db, fieldName);

    if (fieldName != ModelDescription.ID_FIELDNAME) {
      var rawValue = entity.properties[propertyName];
      var value = prop.decodePrimitiveValue(db, rawValue);

      if (!prop.validate(db, value)) {
        throw new StateError('Property validation failed while '
            'trying to deserialize entity of kind '
            '${entity.key.elements.last.kind} (property name: $prop)');
      }

      mirror.setField(mirrors.MirrorSystem.getSymbol(fieldName), value);
    }
  }

  Query finishQuery(ModelDB db, Query q) => q;

  String fieldNameToPropertyName(ModelDB db, String fieldName) {
    List stateVector =  db.modelDescriptionState(this);
    return stateVector[STATE_FIELDNAME_TO_PROPERTYNAME_MAP][fieldName];
  }

  String propertyNameToFieldName(ModelDB db, String propertySearchName) {
    List stateVector =  db.modelDescriptionState(this);
    return stateVector[STATE_PROPERTYNAME_TO_FIELDNAME_MAP][propertySearchName];
  }

  Object encodeField(ModelDB db, String fieldName, Object value) {
    Property property = db.propertiesForModel(this)[fieldName];
    if (property != null) return property.encodeValue(db, value);
    return null;
  }
}

// NOTE/TODO:
// Currently expanded properties are only
//   * decoded if there are no clashes in [usedNames]
//   * encoded if there are no clashes in [usedNames]
// We might want to throw an error if there are clashes, because otherwise
//   - we may end up removing properties after a read-write cycle
//   - we may end up dropping added properties in a write
// ([usedNames] := [realFieldNames] + [realPropertyNames])
abstract class ExpandoModelDescription extends ModelDescription {
  static const int STATE_FIELD_SET = ModelDescription.STATE_LAST + 1;
  static const int STATE_PROPERTY_SET = ModelDescription.STATE_LAST + 2;
  static const int STATE_USED_NAMES = ModelDescription.STATE_LAST + 3;
  static const int STATE_LAST = STATE_USED_NAMES;

  const ExpandoModelDescription(String kind) : super(kind);

  initialize(ModelDB db) {
    var stateVector = super.initialize(db);

    var realFieldNames = new Set<String>.from(
        stateVector[ModelDescription.STATE_FIELDNAME_TO_PROPERTYNAME_MAP].keys);
    var realPropertyNames = new Set<String>.from(
        stateVector[ModelDescription.STATE_PROPERTYNAME_TO_FIELDNAME_MAP].keys);
    var usedNames =
        new Set()..addAll(realFieldNames)..addAll(realPropertyNames);

    // NOPTE: [realFieldNames] and [realPropertyNames] are not used right now
    // but we might use them to detect name clashes in the future.
    return new List.from([]
        ..addAll(stateVector)
        ..add(realFieldNames)
        ..add(realPropertyNames)
        ..add(usedNames),
        growable: false);
  }

  datastore.Entity encodeModel(ModelDB db, ExpandoModel model) {
    List stateVector =  db.modelDescriptionState(this);
    Set<String> usedNames = stateVector[STATE_USED_NAMES];

    var entity = super.encodeModel(db, model);
    var properties = entity.properties;
    model.additionalProperties.forEach((String key, Object value) {
      // NOTE: All expanded properties will be indexed.
      if (!usedNames.contains(key)) {
        properties[key] = value;
      }
    });
    return entity;
  }

  Model decodeEntity(ModelDB db, Key key, datastore.Entity entity) {
    if (entity == null) return null;

    List stateVector =  db.modelDescriptionState(this);
    Set<String> usedNames = stateVector[STATE_USED_NAMES];

    ExpandoModel model = super.decodeEntity(db, key, entity);
    var properties = entity.properties;
    properties.forEach((String key, Object value) {
      if (!usedNames.contains(key)) {
        model.additionalProperties[key] = value;
      }
    });
    return model;
  }

  String fieldNameToPropertyName(ModelDB db, String fieldName) {
    String propertyName = super.fieldNameToPropertyName(db, fieldName);
    // If the ModelDescription doesn't know about [fieldName], it's an
    // expanded property, where propertyName == fieldName.
    if (propertyName == null) propertyName = fieldName;
    return propertyName;
  }

  String propertyNameToFieldName(ModelDB db, String propertyName) {
    String fieldName = super.propertyNameToFieldName(db, propertyName);
    // If the ModelDescription doesn't know about [propertyName], it's an
    // expanded property, where propertyName == fieldName.
    if (fieldName == null) fieldName = propertyName;
    return fieldName;
  }

  Object encodeField(ModelDB db, String fieldName, Object value) {
    Object primitiveValue = super.encodeField(db, fieldName, value);
    // If superclass can't encode field, we return value here (and assume
    // it's primitive)
    // NOTE: Implicit assumption:
    // If value != null then superclass will return != null.
    // TODO: Ensure [value] is primitive in this case.
    if (primitiveValue == null) primitiveValue = value;
    return primitiveValue;
  }
}
