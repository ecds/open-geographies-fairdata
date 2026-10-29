# CoreDataConnector::OpenGeographies

Short description and motivation.

## Usage

How to use my plugin.

## Installation

Add this line to your application's Gemfile:

```ruby
gem "core_data_connector_open_geographies"
```

And then execute:

```bash
$ bundle
```

Or install it yourself as:

```bash
$ gem install core_data_connector_open_geographies
```

## Development

The gem is a Rails engine. Its specs run inside a small Rails app in
`spec/dummy` against a real Postgres (with PostGIS) and a real
Elasticsearch, so you need Ruby plus those two services.

### Windows: use WSL

rbenv doesn't run on Windows, and several gems here build against Linux
libraries. Do everything inside WSL 2 with Ubuntu:

1. In PowerShell as administrator, run `wsl --install -d Ubuntu`, restart,
   and create a Linux user when Ubuntu first opens.
2. Install Docker Desktop and, under Settings → Resources → WSL integration,
   turn it on for Ubuntu.
3. Clone the repository inside Ubuntu, e.g. under `~/code`, not under
   `/mnt/c/...`. The Windows drive is slow from WSL and can change line
   endings.

Run every command below in the Ubuntu terminal. VS Code's WSL extension
opens the folder from there.

### Ruby

The Ruby version is in `.ruby-version`. Install it with rbenv.

On Ubuntu (including WSL), first the libraries Ruby and the gems compile
against:

```bash
sudo apt update
sudo apt install -y git curl build-essential autoconf libssl-dev libyaml-dev zlib1g-dev libffi-dev libreadline-dev libgmp-dev libpq-dev libcurl4-openssl-dev libgeos-dev
```

then rbenv and its `ruby-build` plugin:

```bash
git clone https://github.com/rbenv/rbenv.git ~/.rbenv
git clone https://github.com/rbenv/ruby-build.git ~/.rbenv/plugins/ruby-build
echo 'eval "$(~/.rbenv/bin/rbenv init - bash)"' >> ~/.bashrc
exec bash
```

On macOS, with Homebrew:

```bash
brew install rbenv ruby-build libpq geos
echo 'eval "$(rbenv init - zsh)"' >> ~/.zshrc
exec zsh
bundle config build.pg --with-pg-config="$(brew --prefix libpq)/bin/pg_config"
```

Then, from the repository root, install that Ruby (this compiles it and
takes several minutes) and the gems:

```bash
rbenv install
gem install bundler -v 2.6.7
bundle install
```

`ruby -v` in the repository should print the version in `.ruby-version`.
If it doesn't, the `rbenv init` line isn't in your shell's startup file.

### Postgres and Elasticsearch

Start the containers with the project's Docker Compose file:

```bash
docker compose up -d
```

The specs expect:

- Postgres with PostGIS on `localhost:5432`, user `postgres`, password
  `postgres`. Set `DB_HOSTNAME`, `DB_USERNAME`, `DB_PASSWORD` or `DB_NAME`
  if yours differ (see `spec/dummy/config/database.yml`).
- Elasticsearch 8 on `localhost:9200` with security off (no password, plain
  `http`). `curl localhost:9200` should print its version.

Redis is not needed for the specs.

The development and test environments share one database,
`open_geographies`, and the specs empty it on every run. Don't keep data
there that you want to keep.

### Running the specs

Create the database once:

```bash
cd spec/dummy && RAILS_ENV=test bin/rails db:create && cd ../..
```

Then, from the repository root:

```bash
RAILS_ENV=test bundle exec rspec
```

The first run loads `spec/dummy/db/schema.rb` into the database. Run one
file or one example by path, e.g. `bundle exec rspec
spec/models/open_geographies/v1/indexes_spec.rb:81`.

Run the specs from the repository root, not from `spec/dummy`: Rails looks
for pending migrations in `db/migrate` relative to where you run it, and
the engine's own migrations live in the root's `db/migrate`.

Check style before pushing:

```bash
bin/rubocop
```

### Good to know

- **Use `spec/dummy/bin/rails`, not `bin/rails`.** The root `bin/rails`
  doesn't work. For a console or a one-off script against the test app,
  either `cd spec/dummy && RAILS_ENV=test bin/rails console`, or from the
  root:

  ```bash
  RAILS_ENV=test bundle exec ruby -e 'require "./spec/dummy/config/environment"; puts CoreDataConnector::Project.count'
  ```

- **"Migrations are pending" after the schema was reloaded.** Loading
  `schema.rb` only records the migrations Rails can see from where it ran.
  If rspec then aborts listing the engine's migrations (the files in the
  root's `db/migrate`) as pending, record them as run; the tables are
  already in `schema.rb`:

  ```bash
  RAILS_ENV=test bundle exec ruby -e 'require "./spec/dummy/config/environment"; ctx = ActiveRecord::Base.connection_pool.migration_context; ctx.migrations.each { |m| ctx.schema_migration.create_version(m.version.to_s) unless ctx.get_all_versions.include?(m.version) }'
  ```

- **`spec/seeds.rb` runs before every suite** and adds 15 places, so
  don't write specs that assume an empty database or index.
- **The indexing specs use real Elasticsearch indexes.** They delete what
  they create. If a run is interrupted, list what's left with
  `curl 'localhost:9200/_cat/indices/open_geographies_v1*'` and delete
  each by name with `curl -X DELETE localhost:9200/<name>` (Elasticsearch
  refuses wildcard deletes).
- **The test log rotates at 100 MB** to `spec/dummy/log/test.log.0`. Both
  are ignored by git; delete them whenever you like.

## v1 API — example documents

Illustrative `search_data` output for the v1 (canonical/OG-compliant) indexer -
i.e. what a Place or Map Layer document looks like once a project uses the
exact relationship/UDF names from `canonical_template.json` and picks up the
`og.promote` shortcuts. Field values below are illustrative (some UUIDs are
made up), but the _shape_ and the concrete numbers that could be pulled from
real data (the church's coordinates, the map layer's bbox) are real, taken
from production while building this out. A non-compliant project (e.g. the
existing HRCGA churches data, which uses names like "Categories" instead of
"Types") still indexes fully, just under its own raw relationship/UDF names
instead of these promoted ones - see `PromotedRelationships` for the
exact-match rule.

### Place

Fully fabricated - Atlanta, GA standing in for a real record - chosen so the
`media` array could show all five `media_type` options
(`image`/`video`/`audio`/`pano`/`model3d` per `canonical_template.json`'s
Media UDF) plus a spread of real-looking `identifiers`, neither of which the
actual HRCGA production data has examples of today.

```json
{
  "uuid": "8f1a2b3c-4d5e-6f70-8192-a3b4c5d6e7f8",
  "slug": "atlanta",
  "slugs": ["atlanta", "atlanta-georgia"],
  "project_id": "2",
  "project": "historic-rural-churches-of-georgia",
  "model_type": "place",
  "model_id": "20",
  "model_name": "Places",
  "name": "Atlanta",
  "visibility": "published",
  "date_modified": "2026-06-01T12:00:00Z",
  "identifiers": [
    {
      "authority": "wikidata",
      "identifier": "https://www.wikidata.org/wiki/Q23556"
    },
    {
      "authority": "geonames",
      "identifier": "https://www.geonames.org/4180439"
    },
    { "authority": "viaf", "identifier": "https://viaf.org/viaf/142294851/" }
  ],
  "geo": { "point": { "lat": 33.748997, "lon": -84.387985 } },
  "administrative_area": [
    {
      "level": "ADM2",
      "name": "Fulton County",
      "geonames_id": "4219762",
      "geonames_url": "https://www.geonames.org/4219762"
    },
    {
      "level": "ADM1",
      "name": "Georgia",
      "geonames_id": "4197000",
      "geonames_url": "https://www.geonames.org/4197000"
    },
    {
      "level": "PCLI",
      "name": "United States",
      "geonames_id": "6252001",
      "geonames_url": "https://www.geonames.org/6252001"
    }
  ],

  "description": "The capital and most populous city of the U.S. state of Georgia, founded in 1837 as the terminus of the Western and Atlantic Railroad.",

  "types": ["City", "State Capital"],

  "contained_in_place": {
    "uuid": "9d2f1e3a-6b7a-4b9d-8b3a-1a2c3d4e5f60",
    "slug": "fulton-county",
    "name": "Fulton County"
  },

  "media": [
    {
      "uuid": "fcd7b531-11b7-4a63-85f4-95a7e01ab8f3",
      "slug": "atlanta-skyline-from-jackson-street-bridge",
      "project_id": "2",
      "project": "historic-rural-churches-of-georgia",
      "model_type": "media",
      "model_id": "22",
      "model_name": "Media",
      "name": "Atlanta Skyline from Jackson Street Bridge",
      "visibility": "published",
      "date_modified": "2025-12-12T22:41:05Z",
      "identifiers": [],
      "media_type": "image",
      "caption": "The downtown Atlanta skyline at dusk, viewed from the Jackson Street Bridge.",
      "alt_text": "City skyline with illuminated skyscrapers against a dusk sky.",
      "preview": "https://iiif-cloud.ecds.io/public/resources/b0db0663-7dd9-4d2a-9d10-0234ba00ede4/preview",
      "thumbnail": "https://iiif-cloud.ecds.io/public/resources/b0db0663-7dd9-4d2a-9d10-0234ba00ede4/thumbnail",
      "content_url": "https://iiif-cloud.ecds.io/public/resources/b0db0663-7dd9-4d2a-9d10-0234ba00ede4/iiif",
      "manifest_url": "https://iiif-cloud.ecds.io/public/resources/b0db0663-7dd9-4d2a-9d10-0234ba00ede4/manifest",
      "creator": {
        "uuid": "2b6f9c1d-4a3e-4f8b-9c2d-6e1a8b3c5d70",
        "slug": "atlanta-history-center",
        "project_id": "2",
        "project": "historic-rural-churches-of-georgia",
        "model_type": "organization",
        "model_id": "23",
        "model_name": "Organizations",
        "name": "Atlanta History Center",
        "visibility": "published",
        "date_modified": "2025-01-01T00:00:00Z",
        "identifiers": []
      }
    },
    {
      "uuid": "1c8e4a2f-6b3d-4e9c-8a1f-2b3c4d5e6f70",
      "slug": "piedmont-park-centennial-documentary",
      "project_id": "2",
      "project": "historic-rural-churches-of-georgia",
      "model_type": "media",
      "model_id": "22",
      "model_name": "Media",
      "name": "Piedmont Park: A Centennial History",
      "visibility": "published",
      "date_modified": "2025-11-03T16:20:00Z",
      "identifiers": [],
      "media_type": "video",
      "caption": "A short documentary on the centennial of Piedmont Park, produced for the Atlanta History Center.",
      "duration": 184,
      "embed_url": "https://www.youtube.com/embed/dQw4w9WgXcQ"
    },
    {
      "uuid": "4d9f2a1c-7e5b-4c8d-9a3f-1b2c3d4e5f80",
      "slug": "sweet-auburn-oral-history-1998",
      "project_id": "2",
      "project": "historic-rural-churches-of-georgia",
      "model_type": "media",
      "model_id": "22",
      "model_name": "Media",
      "name": "Sweet Auburn Oral History, 1998",
      "visibility": "published",
      "date_modified": "2025-08-15T10:05:00Z",
      "identifiers": [],
      "media_type": "audio",
      "caption": "Oral history interview with a longtime Sweet Auburn resident, recorded 1998.",
      "duration": 2745,
      "content_url": "https://iiif-cloud.ecds.io/public/resources/c1a2b3d4-5e6f-4a7b-8c9d-0e1f2a3b4c50/audio"
    },
    {
      "uuid": "7a3b5c9d-2e4f-4b1a-9c8d-3e4f5a6b7c80",
      "slug": "centennial-olympic-park-360",
      "project_id": "2",
      "project": "historic-rural-churches-of-georgia",
      "model_type": "media",
      "model_id": "22",
      "model_name": "Media",
      "name": "Centennial Olympic Park, 360°",
      "visibility": "published",
      "date_modified": "2025-09-20T13:45:00Z",
      "identifiers": [],
      "media_type": "pano",
      "caption": "A 360° panorama of the Fountain of Rings at Centennial Olympic Park.",
      "embed_url": "https://my.matterport.com/show/?m=examplePanoId"
    },
    {
      "uuid": "5e7f9a1b-3c2d-4e6f-8a9b-1c2d3e4f5a60",
      "slug": "hurt-building-lobby-3d-scan",
      "project_id": "2",
      "project": "historic-rural-churches-of-georgia",
      "model_type": "media",
      "model_id": "22",
      "model_name": "Media",
      "name": "Hurt Building Lobby, 3D Scan",
      "visibility": "published",
      "date_modified": "2025-07-01T08:30:00Z",
      "identifiers": [],
      "media_type": "model3d",
      "caption": "Photogrammetric 3D model of the Hurt Building's Beaux-Arts lobby.",
      "embed_url": "https://sketchfab.com/models/exampleModelId/embed"
    }
  ],

  "map_layers": [
    {
      "uuid": "3f2a9c7e-8b1d-4e5a-9c3f-7d2b4a6e8f10",
      "slug": "hilliard-1943-topographic-survey",
      "project_id": "5",
      "project": "sample-atlas",
      "model_type": "map_layer",
      "model_id": "48",
      "model_name": "Map Layers",
      "name": "Hilliard, 1943",
      "visibility": "published",
      "date_modified": "2026-03-10T14:02:11Z",
      "identifiers": [],
      "bbox": {
        "type": "envelope",
        "coordinates": [
          [-82.0000001, 30.749996],
          [-81.87499909, 30.62500399]
        ]
      }
    }
  ],

  "featured_media": {
    "uuid": "fcd7b531-11b7-4a63-85f4-95a7e01ab8f3",
    "slug": "atlanta-skyline-from-jackson-street-bridge",
    "project_id": "2",
    "project": "historic-rural-churches-of-georgia",
    "model_type": "media",
    "model_id": "22",
    "model_name": "Media",
    "name": "Atlanta Skyline from Jackson Street Bridge",
    "visibility": "published",
    "date_modified": "2025-12-12T22:41:05Z",
    "identifiers": []
  }
}
```

Notes on what this demonstrates: `types` is a bare string array (taxonomy
promotions are names only, for faceting); `contained_in_place` and
`featured_media` are single objects; `media` and `map_layers` are arrays of
depth-limited summaries. `identifiers` shows the `sameAs`-style shape built
by `IDENTIFIER_URL_BUILDERS` - each authority's stored bare code (e.g. a
GeoNames numeric ID) turned into its canonical public URL.

`administrative_area` is deliberately a _different_ thing from
`contained_in_place`, even though this example has both pointing at the same
real-world county. `contained_in_place` requires a curator to have actually
built a County place record and related it - a real local record with a
uuid/slug a client can link to. `administrative_area` needs no curator effort
at all: `V1::Place#extras` reverse-geocodes the place's own centroid against
GeoNames (`extendedFindNearbyJSON`, walking the full admin chain rather than
a fixed level so it isn't U.S.-specific) and caches the result in
`GeonamesHierarchy`, keyed on `place_id`, refetched only when the place's
geometry actually moves. Its entries are just facet-able names/IDs, not
local records - no uuid/slug, since there's nothing in the corpus to link to.
A project that never builds county records still gets basic geographic
faceting; one that does gets both.

`project` (alongside `project_id`) is what makes `contained_in_place`
actually followable rather than just descriptive. v1's routes key on the
project's parameterized name, not its numeric id (`GET
/v1/:project/places/:slug`) - a record's own top-level document doesn't need
this (the client already knows what project it asked for), but a _nested_
summary might belong to a completely different project than the record
containing it. That's exactly the shape a shared, `discoverable` reference
project (e.g. one atlas-wide "Administrative Districts" project that every
atlas's `Contained In` relationship points into, instead of every atlas
hand-building its own counties) would produce - without `project`, a client
would have a county's `project_id` and no way to turn it into a URL at all.

The `media` array shows both branches of "exactly one of content urls or
embed URL must be present" from the canonical template's Media model: the
image is uploaded/IIIF-backed (`preview`/`thumbnail`/`content_url`/
`manifest_url`, from `V1::MediaContent#extras`), while the video, pano, and
3D model are externally hosted (`embed_url` only, from _UDF promotion_, not
`extras` - "Embed URL" is just a regular UDF on the Media project model that
happens to promote to a structural field, same mechanism as Map Layers'
`date`/`bearing`). `media_type`/`caption`/`alt_text`/`duration` are UDF
promotions too. The nested `media[0]` also shows one more level of expansion
(its own `creator`) - and that creator is _just_ the flat envelope, with no
further relationships, because depth capping stops recursion there.

### Map Layer

```json
{
  "uuid": "3f2a9c7e-8b1d-4e5a-9c3f-7d2b4a6e8f10",
  "slug": "hilliard-1943-topographic-survey",
  "slugs": ["hilliard-1943-topographic-survey"],
  "project_id": "5",
  "project": "sample-atlas",
  "model_type": "map_layer",
  "model_id": "48",
  "model_name": "Map Layers",
  "name": "Hilliard, 1943",
  "visibility": "published",
  "date_modified": "2026-03-10T14:02:11Z",
  "identifiers": [],

  "bbox": {
    "type": "envelope",
    "coordinates": [
      [-82.0000001, 30.749996],
      [-81.87499909, 30.62500399]
    ]
  },
  "date": "1943",
  "bearing": 0,
  "source": {
    "type": "wms",
    "urls": ["https://maps.gastateparks.org/geoserver/wms"]
  },
  "description": "USGS 15-minute topographic quadrangle covering the Hilliard area, surveyed in 1943.",

  "preview": {
    "uuid": "a1c4e7f2-5b9d-4e3a-8c6f-1d2b3a4e5f60",
    "slug": "hilliard-1943-preview",
    "project_id": "5",
    "project": "sample-atlas",
    "model_type": "media",
    "model_id": "49",
    "model_name": "Media",
    "name": "Hilliard 1943 preview",
    "visibility": "published",
    "date_modified": "2026-03-10T14:00:00Z",
    "identifiers": [],
    "thumbnail": "https://iiif-cloud.ecds.io/public/resources/.../thumbnail"
  },
  "publisher": {
    "uuid": "6e2d8b41-3c5a-4f7e-9b1d-2a4c6e8f0a10",
    "slug": "us-geological-survey",
    "project_id": "5",
    "project": "sample-atlas",
    "model_type": "organization",
    "model_id": "50",
    "model_name": "Organizations",
    "name": "U.S. Geological Survey",
    "visibility": "published",
    "date_modified": "2020-01-01T00:00:00Z",
    "identifiers": []
  },

  "places": [
    {
      "uuid": "e6c220f2-db9d-4072-8585-65c934225a1e",
      "slug": "evergreen-congregational-church-and-school",
      "project_id": "2",
      "project": "historic-rural-churches-of-georgia",
      "model_type": "place",
      "model_id": "20",
      "model_name": "Places",
      "name": "Evergreen Congregational Church and School",
      "visibility": "published",
      "date_modified": "2026-04-21T20:42:35Z",
      "identifiers": [],
      "geo": { "point": { "lat": 30.727751, "lon": -84.13654799999999 } }
    }
  ]
}
```

The `bbox` coordinates here are real - pulled from an actual production Place
geometry (`ST_XMin/XMax/YMin/YMax` over a real topographic-quad record) via
`V1::MapLayer#extras`, not invented. `date`/`bearing`/`source` come from
scalar UDF promotion (`"Source Type"` + `"Source URLs"` merge into one
`source: {type:, urls:}` object via the dotted `og.promote` path). `places`
is the _inverse_ of a Place's `map_layers` relationship - it needs no
map-layer-specific code, since `related_to` already walks
`allow_inverse: true` relationships generically.

**Building these examples surfaced two mapping bugs, now fixed**: the nested
`places` object in both `es_mapping.json` and `es_mapping_map_layers.json`
was typed as `location: geo_point`, but the code actually produces
`geo: {point: {...}}` (matching `V1::Place#extras`) - fixed to match. The
nested `map_layers` object's `bbox` was typed `double`; it's actually a
geo_shape envelope object - fixed too.

**Not yet reconciled**: the nested `media` mapping property (in
`es_mapping.json`) expects `thumbnail_url`/`content_url`/`embed_url`/
`media_type`, but `V1::MediaContent#extras` actually produces
`preview`/`thumbnail`/`content_url`/`manifest_url` - some names match, some
don't, and `media_type`/`embed_url` are never populated by any current code
path. Left as-is pending a decision on which naming wins (the draft mapping's
or the already-implemented extras) rather than picking one silently.

## Contributing

Contribution directions go here.

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).
