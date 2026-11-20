

BEGIN;

-- 0. Extensions

CREATE EXTENSION IF NOT EXISTS postgis;


-- Automatically update the updated_at column whenever a record is modified.

CREATE OR REPLACE FUNCTION set_updated_at()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    NEW.updated_at := now();
    RETURN NEW;
END;
$$;


-- 2. Tables


-- A. city 
CREATE TABLE city (
    city_id     integer GENERATED ALWAYS AS IDENTITY,
    name        varchar(100) NOT NULL,
    boundary    geometry(MultiPolygon, 4326),          -- nullable until loaded
    created_at  timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT pk_city PRIMARY KEY (city_id),
    CONSTRAINT uq_city_name UNIQUE (name),
    CONSTRAINT ck_city_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT ck_city_boundary_valid
        CHECK (boundary IS NULL OR (ST_IsValid(boundary) AND NOT ST_IsEmpty(boundary)))
);

COMMENT ON TABLE  city          IS 'Cities covered by the platform (Rabat, Salé).';
COMMENT ON COLUMN city.boundary IS 'City limits, MultiPolygon in EPSG:4326.';

-- B. district 
CREATE TABLE district (
    district_id    integer GENERATED ALWAYS AS IDENTITY,
    city_id        integer      NOT NULL,
    name           varchar(150) NOT NULL,
    district_type  varchar(50),                          -- arrondissement, commune, quartier...
    population     integer,
    boundary       geometry(MultiPolygon, 4326) NOT NULL,

    CONSTRAINT pk_district PRIMARY KEY (district_id),
    CONSTRAINT fk_district_city
        FOREIGN KEY (city_id) REFERENCES city (city_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT uq_district_city_name UNIQUE (city_id, name),
    CONSTRAINT ck_district_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT ck_district_population CHECK (population IS NULL OR population >= 0),
    CONSTRAINT ck_district_boundary_valid
        CHECK (ST_IsValid(boundary) AND NOT ST_IsEmpty(boundary))
);

COMMENT ON TABLE  district          IS 'Administrative districts / neighbourhoods. A place''s district is derived spatially (ST_Contains), not stored.';
COMMENT ON COLUMN district.boundary IS 'MultiPolygon in EPSG:4326. Transform to 32629 for area computations.';

-- C. category 
CREATE TABLE category (
    category_id  integer GENERATED ALWAYS AS IDENTITY,
    name         varchar(100) NOT NULL,
    description  text,
    icon         varchar(100),                           -- icon name/path used by Leaflet

    CONSTRAINT pk_category PRIMARY KEY (category_id),
    CONSTRAINT uq_category_name UNIQUE (name),
    CONSTRAINT ck_category_name_not_blank CHECK (btrim(name) <> '')
);

COMMENT ON TABLE category IS 'Flat list of place categories (no parent / subcategories).';

-- D. place --------------------------------------------------------------------
CREATE TABLE place (
    place_id       integer GENERATED ALWAYS AS IDENTITY,
    category_id    integer      NOT NULL,
    name           varchar(200) NOT NULL,
    name_ar        varchar(200),
    description    text,
    address        varchar(255),
    phone          varchar(30),
    website        varchar(255),
    opening_hours  varchar(255),                         -- free text, e.g. OSM opening_hours syntax
    price_level    smallint,                             -- 1 (cheap) .. 4 (expensive)
    attributes     jsonb        NOT NULL DEFAULT '{}'::jsonb,
    source         varchar(30),                          -- 'openstreetmap', 'manual', ...
    source_id      varchar(50),                          -- external identifier (e.g. OSM id)
    is_active      boolean      NOT NULL DEFAULT true,
    location       geometry(Point, 4326) NOT NULL,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT pk_place PRIMARY KEY (place_id),
    CONSTRAINT fk_place_category
        FOREIGN KEY (category_id) REFERENCES category (category_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,
    CONSTRAINT ck_place_name_not_blank CHECK (btrim(name) <> ''),
    CONSTRAINT ck_place_price_level CHECK (price_level IS NULL OR price_level BETWEEN 1 AND 4),
    CONSTRAINT ck_place_attributes_object CHECK (jsonb_typeof(attributes) = 'object'),
    -- an external id only makes sense together with its source
    CONSTRAINT ck_place_source_id_requires_source
        CHECK (source_id IS NULL OR source IS NOT NULL),
    -- ST_IsValid() returns TRUE for empty geometries (e.g. POINT EMPTY),
    -- so emptiness must be rejected explicitly.
    CONSTRAINT ck_place_location_valid
        CHECK (ST_IsValid(location) AND NOT ST_IsEmpty(location)),
    -- Study-area bounding box (lon/lat), deliberately generous: it only exists
    -- to catch gross import errors (swapped lat/lon, wrong CRS, 0/0 points).
    -- It is a named constraint, so it can be widened or dropped without
    -- touching data: ALTER TABLE place DROP CONSTRAINT ck_place_location_study_area;
    CONSTRAINT ck_place_location_study_area
        CHECK (location && ST_MakeEnvelope(-7.15, 33.80, -6.55, 34.25, 4326))
);

-- Prevent duplicate imports: unique only when BOTH source and source_id exist
CREATE UNIQUE INDEX uq_place_source_source_id
    ON place (source, source_id)
    WHERE source IS NOT NULL AND source_id IS NOT NULL;

COMMENT ON TABLE  place            IS 'All tourist points of interest in one generic table.';
COMMENT ON COLUMN place.attributes IS 'Category-specific data (hotel stars, cuisine, entry fee...). JSON object.';
COMMENT ON COLUMN place.location   IS 'Point in EPSG:4326 (lon, lat).';

-- E. app_user -----------------------------------------------------------------
-- Passwords are hashed by the backend (e.g. bcrypt/argon2); only the hash is stored.
CREATE TABLE app_user (
    user_id        integer GENERATED ALWAYS AS IDENTITY,
    full_name      varchar(150) NOT NULL,
    email          varchar(255) NOT NULL,
    password_hash  varchar(255) NOT NULL,
    role           varchar(20)  NOT NULL DEFAULT 'tourist',
    is_active      boolean      NOT NULL DEFAULT true,
    created_at     timestamptz  NOT NULL DEFAULT now(),
    updated_at     timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT pk_app_user PRIMARY KEY (user_id),
    CONSTRAINT ck_app_user_full_name_not_blank CHECK (btrim(full_name) <> ''),
    -- Real email validation is done in the backend (Pydantic EmailStr).
    -- The database only enforces a minimal sanity check and the normalised form
    -- (trimmed, lowercase), so the unique index on lower(email) is consistent.
    CONSTRAINT ck_app_user_email_sanity
        CHECK (email = lower(btrim(email)) AND email LIKE '_%@_%'),
    CONSTRAINT ck_app_user_role CHECK (role IN ('tourist', 'admin')),
    CONSTRAINT ck_app_user_password_hash_not_blank CHECK (btrim(password_hash) <> '')
);

-- Case-insensitive uniqueness: Test@x.com and test@x.com are the same account.
-- The backend should normalise emails (lowercase) before insert.
CREATE UNIQUE INDEX uq_app_user_email_lower ON app_user (lower(email));

COMMENT ON TABLE  app_user               IS 'Registered tourists. Authentication logic lives in the backend.';
COMMENT ON COLUMN app_user.password_hash IS 'Hash produced by the backend. Never store plain-text passwords.';

-- F. itinerary ----------------------------------------------------------------
CREATE TABLE itinerary (
    itinerary_id    integer GENERATED ALWAYS AS IDENTITY,
    user_id         integer      NOT NULL,
    title           varchar(150) NOT NULL,
    description     text,
    transport_mode  varchar(20)  NOT NULL DEFAULT 'walking',
    created_at      timestamptz  NOT NULL DEFAULT now(),
    updated_at      timestamptz  NOT NULL DEFAULT now(),

    CONSTRAINT pk_itinerary PRIMARY KEY (itinerary_id),
    CONSTRAINT fk_itinerary_user
        FOREIGN KEY (user_id) REFERENCES app_user (user_id)
        ON UPDATE CASCADE ON DELETE CASCADE,            -- deleting a user removes their itineraries
    CONSTRAINT ck_itinerary_title_not_blank CHECK (btrim(title) <> ''),
    CONSTRAINT ck_itinerary_transport_mode
        CHECK (transport_mode IN ('walking', 'driving', 'transit'))
);

COMMENT ON TABLE itinerary IS 'Itineraries created by registered users (each belongs to exactly one user).';

-- G. itinerary_stop -----------------------------------------------------------
-- Both uniqueness rules are DEFERRABLE so a stop can be re-ordered inside one
-- transaction (e.g. swapping order 2 and 3) without a transient violation.
CREATE TABLE itinerary_stop (
    itinerary_id          integer  NOT NULL,
    stop_order            smallint NOT NULL,
    place_id              integer  NOT NULL,
    planned_duration_min  smallint,
    notes                 text,

    CONSTRAINT pk_itinerary_stop
        PRIMARY KEY (itinerary_id, stop_order)          -- no duplicate order in an itinerary
        DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT uq_itinerary_stop_place
        UNIQUE (itinerary_id, place_id)                 -- same place at most once per itinerary
        DEFERRABLE INITIALLY DEFERRED,
    CONSTRAINT fk_itinerary_stop_itinerary
        FOREIGN KEY (itinerary_id) REFERENCES itinerary (itinerary_id)
        ON UPDATE CASCADE ON DELETE CASCADE,
    CONSTRAINT fk_itinerary_stop_place
        FOREIGN KEY (place_id) REFERENCES place (place_id)
        ON UPDATE CASCADE ON DELETE RESTRICT,           -- deactivate places instead of deleting
    CONSTRAINT ck_itinerary_stop_order CHECK (stop_order > 0),
    CONSTRAINT ck_itinerary_stop_duration
        CHECK (planned_duration_min IS NULL OR planned_duration_min > 0)
);

COMMENT ON TABLE itinerary_stop IS 'Ordered places of an itinerary (resolves itinerary <-> place N:N).';

-- -----------------------------------------------------------------------------
-- 3. Indexes
-- -----------------------------------------------------------------------------

-- 3.1 Spatial (GiST) on every geometry column
CREATE INDEX idx_city_boundary      ON city      USING GIST (boundary);
CREATE INDEX idx_district_boundary  ON district  USING GIST (boundary);
CREATE INDEX idx_place_location     ON place     USING GIST (location);

-- 3.2 B-tree on foreign keys
-- (district.city_id is already covered by uq_district_city_name (city_id, name);
--  itinerary_stop.itinerary_id is covered by its primary key.)
CREATE INDEX idx_place_category_id           ON place          (category_id);
CREATE INDEX idx_itinerary_user_id           ON itinerary      (user_id);
CREATE INDEX idx_itinerary_stop_place_id     ON itinerary_stop (place_id);

-- 3.3 Frequently searched / filtered columns
CREATE INDEX idx_place_name_lower            ON place (lower(name));
CREATE INDEX idx_place_active_category       ON place (category_id) WHERE is_active;
CREATE INDEX idx_place_attributes_gin        ON place USING GIN (attributes jsonb_path_ops);
CREATE INDEX idx_district_name_lower         ON district (lower(name));

-- -----------------------------------------------------------------------------
-- 4. Triggers (updated_at)
-- -----------------------------------------------------------------------------
CREATE TRIGGER trg_place_updated_at
    BEFORE UPDATE ON place
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_app_user_updated_at
    BEFORE UPDATE ON app_user
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

CREATE TRIGGER trg_itinerary_updated_at
    BEFORE UPDATE ON itinerary
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- -----------------------------------------------------------------------------
-- 5. Seed data (idempotent)
-- -----------------------------------------------------------------------------
INSERT INTO city (name) VALUES
    ('Rabat'),
    ('Salé')
ON CONFLICT (name) DO NOTHING;

INSERT INTO category (name, description, icon) VALUES
    ('Historical Sites',  'Monuments, kasbahs, ramparts, archaeological sites',  'landmark'),
    ('Museums',           'Museums and art galleries',                           'museum'),
    ('Restaurants',       'Restaurants, cafés and places to eat',                'utensils'),
    ('Hotels',            'Hotels, riads and guesthouses',                       'bed'),
    ('Beaches',           'Beaches and seaside areas',                           'umbrella-beach'),
    ('Parks',             'Parks, gardens and green spaces',                     'tree'),
    ('Cultural Centers',  'Cultural centres, theatres and libraries',            'theater-masks'),
    ('Entertainment',     'Leisure, nightlife and recreational venues',          'ticket'),
    ('Shopping Centers',  'Malls, souks and markets',                            'shopping-bag'),
    ('Religious Sites',   'Mosques, mausoleums and other places of worship',     'mosque')
ON CONFLICT (name) DO NOTHING;

COMMIT;