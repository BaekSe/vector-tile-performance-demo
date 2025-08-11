-- PostGIS 확장 활성화
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS postgis_topology;

-- Martin 최적화를 위한 벡터 타일 테이블 생성
-- 대규모 폴리곤 데이터를 위한 최적화된 스키마
CREATE TABLE IF NOT EXISTS polygons (
    id BIGSERIAL PRIMARY KEY,
    osm_id BIGINT,
    name TEXT,
    name_en TEXT,
    admin_level INTEGER,
    boundary TEXT,
    place TEXT,
    population INTEGER,
    area_km2 NUMERIC,
    geom GEOMETRY(MULTIPOLYGON, 3857), -- Web Mercator for better tile performance
    geom_4326 GEOMETRY(MULTIPOLYGON, 4326), -- WGS84 for compatibility
    
    -- Martin 최적화를 위한 메타데이터
    z_order INTEGER DEFAULT 0,
    way_area REAL
);

-- 벡터 타일링을 위한 공간 인덱스
CREATE INDEX IF NOT EXISTS idx_polygons_geom ON polygons USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_polygons_geom_4326 ON polygons USING GIST (geom_4326);

-- 속성 기반 인덱스 (필터링 최적화)
CREATE INDEX IF NOT EXISTS idx_polygons_admin_level ON polygons (admin_level);
CREATE INDEX IF NOT EXISTS idx_polygons_boundary ON polygons (boundary);
CREATE INDEX IF NOT EXISTS idx_polygons_z_order ON polygons (z_order);

-- 포인트/라인 데이터를 위한 추가 테이블들
CREATE TABLE IF NOT EXISTS points (
    id BIGSERIAL PRIMARY KEY,
    osm_id BIGINT,
    name TEXT,
    name_en TEXT,
    place TEXT,
    population INTEGER,
    geom GEOMETRY(POINT, 3857),
    geom_4326 GEOMETRY(POINT, 4326)
);

CREATE TABLE IF NOT EXISTS lines (
    id BIGSERIAL PRIMARY KEY,
    osm_id BIGINT,
    name TEXT,
    name_en TEXT,
    highway TEXT,
    railway TEXT,
    waterway TEXT,
    geom GEOMETRY(LINESTRING, 3857),
    geom_4326 GEOMETRY(LINESTRING, 4326)
);

-- 포인트/라인 인덱스
CREATE INDEX IF NOT EXISTS idx_points_geom ON points USING GIST (geom);
CREATE INDEX IF NOT EXISTS idx_lines_geom ON lines USING GIST (geom);

-- Martin이 테이블을 인식할 수 있도록 권한 설정
GRANT SELECT ON ALL TABLES IN SCHEMA public TO martin_user;
GRANT USAGE ON ALL SEQUENCES IN SCHEMA public TO martin_user;