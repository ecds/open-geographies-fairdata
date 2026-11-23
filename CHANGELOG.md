# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Until 1.0.0, a minor
release may change the shape of v1 documents.

## [0.1.0] - 2026-11-23

The first release. It indexes FairData (Core Data) records as Open Geographies
documents in Elasticsearch and serves them through a read-only API.

### Added

- **v1 API**, mounted under `/v1/:project`:
  - `places` and `places/:slug`, with full-text search, facets and paging;
  - `map_layers` and `map_layers/:slug`, filtered by bounding box (`bbox`);
  - `map_layers/:slug/annotation`, which serves a map layer's stored IIIF
    georeference annotation page and allows any origin to read it;
  - `tours/:slug`.
- **v1 documents** for places, media, works, people, organizations, events,
  items, instances, taxonomies, tours and map layers:
  - the template's relationships and fields are written under fixed keys
    (`contained_in_place`, `featured_media`, `preview_media`, `publisher` and
    others), from `canonical_template.json`;
  - a relationship row flagged as featured is also written at
    `featured_<relationship>`;
  - other curator fields and relationships are written under a key made from
    their name. A name that clashes with a mapped field, such as Date or
    Preview, is written as `<name>_2`;
  - place geometry is indexed as a point and, for polygons, as a `geo_shape`;
    a map layer's extent is indexed as a `geo_shape` bounding box;
  - each place gets its administrative areas from GeoNames, looked up from its
    centroid and cached;
  - every document carries `@context`
    (`https://opengeographies.org/api/v1/context.json`).
- **Elasticsearch mappings** for records (`es_mapping.json`) and map layers
  (`es_mapping_map_layers.json`), for Elasticsearch 8.
- **Per-project indexes.** `OG_INDEX_LAYOUT` selects `shared`, `both` or
  `per_project`. Each project's index is `open_geographies_v1_project_<id>`
  behind an alias; map layers have their own index. Under `per_project`, a
  write to a project without an index queues `RebuildIndexJob` to build one.
- **Rake tasks:**
  - `og_indexes:build` builds a project's index and swaps its alias
    (`PROJECT_IDS` limits it);
  - `og_indexes:report` lists each index's documents and fields, and projects
    without one;
  - `og_indexes:drop_shared` deletes the shared index once every project has
    its own;
  - `og_indexes:drop_orphans` deletes indexes of projects that no longer exist;
  - `og_pmtiles:create` builds and publishes a PMTiles file of an atlas's
    places.
- **Reindexing on change.** Saving a FairData record, or one of its
  relationships, reindexes the records whose documents include it.
- **Migrations** for project model roles, the GeoNames cache and index
  rebuild tracking.
- **Unversioned (v0) routes** for places and tours, kept for existing
  consumers.

### Known issues

- A Works record with a Publisher fails to index. The template writes the
  Publisher text field to `publisher`, which the mapping defines as an
  organization object.
- The `@context` URL does not resolve yet.

[0.1.0]: https://github.com/ecds/open-geographies-fairdata/releases/tag/v0.1.0
