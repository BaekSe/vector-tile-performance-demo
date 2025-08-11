#!/bin/bash

# PBF 파일을 PostGIS로 로드하는 스크립트
# osm2pgsql을 사용하여 PBF 파일을 최적화된 테이블 구조로 변환

# 환경 변수 설정
export PGHOST=localhost
export PGPORT=5432
export PGDATABASE=martin_db
export PGUSER=martin_user
export PGPASSWORD=martin_password

# dataset 디렉토리의 모든 PBF 파일 처리
for pbf_file in /dataset/*.pbf; do
    if [ -f "$pbf_file" ]; then
        echo "Processing $pbf_file..."
        
        # osm2pgsql로 PBF 파일 로드 (대규모 폴리곤에 최적화된 설정)
        osm2pgsql \
            --create \
            --database "$PGDATABASE" \
            --username "$PGUSER" \
            --host "$PGHOST" \
            --port "$PGPORT" \
            --prefix osm \
            --hstore \
            --multi-geometry \
            --keep-coastlines \
            --cache 2048 \
            --number-processes 4 \
            --slim \
            --drop \
            --style /usr/share/osm2pgsql/default.style \
            "$pbf_file"
            
        # 폴리곤 데이터를 최적화된 테이블로 이동
        psql -h "$PGHOST" -p "$PGPORT" -U "$PGUSER" -d "$PGDATABASE" << EOF
-- osm2pgsql 결과를 Martin 최적화 테이블로 변환
INSERT INTO polygons (osm_id, name, name_en, admin_level, boundary, place, population, geom, geom_4326, z_order, way_area)
SELECT 
    osm_id,
    COALESCE(tags->'name', name) as name,
    COALESCE(tags->'name:en', tags->'name') as name_en,
    CASE WHEN tags->'admin_level' ~ '^[0-9]+$' THEN (tags->'admin_level')::integer ELSE NULL END as admin_level,
    tags->'boundary' as boundary,
    tags->'place' as place,
    CASE WHEN tags->'population' ~ '^[0-9]+$' THEN (tags->'population')::integer ELSE NULL END as population,
    ST_Transform(way, 3857) as geom,
    ST_Transform(way, 4326) as geom_4326,
    z_order,
    way_area
FROM osm_polygon 
WHERE way IS NOT NULL
ON CONFLICT (osm_id) DO NOTHING;

-- 포인트 데이터 변환
INSERT INTO points (osm_id, name, name_en, place, population, geom, geom_4326)
SELECT 
    osm_id,
    COALESCE(tags->'name', name) as name,
    COALESCE(tags->'name:en', tags->'name') as name_en,
    tags->'place' as place,
    CASE WHEN tags->'population' ~ '^[0-9]+$' THEN (tags->'population')::integer ELSE NULL END as population,
    ST_Transform(way, 3857) as geom,
    ST_Transform(way, 4326) as geom_4326
FROM osm_point 
WHERE way IS NOT NULL AND tags->'place' IS NOT NULL
ON CONFLICT (osm_id) DO NOTHING;

-- 라인 데이터 변환
INSERT INTO lines (osm_id, name, name_en, highway, railway, waterway, geom, geom_4326)
SELECT 
    osm_id,
    COALESCE(tags->'name', name) as name,
    COALESCE(tags->'name:en', tags->'name') as name_en,
    tags->'highway' as highway,
    tags->'railway' as railway,
    tags->'waterway' as waterway,
    ST_Transform(way, 3857) as geom,
    ST_Transform(way, 4326) as geom_4326
FROM osm_line 
WHERE way IS NOT NULL AND (tags->'highway' IS NOT NULL OR tags->'railway' IS NOT NULL OR tags->'waterway' IS NOT NULL)
ON CONFLICT (osm_id) DO NOTHING;

-- 통계 업데이트
ANALYZE polygons;
ANALYZE points;
ANALYZE lines;

-- 결과 출력
SELECT 'Polygons loaded: ' || count(*) FROM polygons;
SELECT 'Points loaded: ' || count(*) FROM points;
SELECT 'Lines loaded: ' || count(*) FROM lines;
EOF
        
        echo "Completed processing $pbf_file"
    fi
done

echo "All PBF files processed!"