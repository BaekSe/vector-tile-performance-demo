#!/bin/bash

# PBF 데이터를 PostGIS로 로딩하는 스크립트

echo "Starting data loading process..."

# PostGIS 컨테이너가 준비될 때까지 대기
echo "Waiting for PostGIS to be ready..."
docker-compose exec postgis bash -c 'while ! pg_isready -h localhost -U martin_user; do sleep 1; done'

# PBF 파일이 있는지 확인
if ls dataset/*.pbf 1> /dev/null 2>&1; then
    echo "Found PBF files in dataset directory"
    
    # osm2pgsql로 직접 PBF 파일 로딩
    echo "Loading data with osm2pgsql..."
    for pbf_file in dataset/*.pbf; do
        if [ -f "$pbf_file" ]; then
            echo "Processing $pbf_file..."
            docker-compose --profile data-loading run --rm osm2pgsql \
                osm2pgsql \
                --create \
                --database martin_db \
                -U martin_user \
                -H postgis \
                -P 5432 \
                --prefix osm \
                --hstore \
                --multi-geometry \
                --cache 1024 \
                --number-processes 2 \
                --slim \
                --drop \
                "/dataset/$(basename "$pbf_file")"
        fi
    done
    
    # 데이터를 최적화된 테이블로 변환
    echo "Converting data to optimized tables..."
    docker-compose exec postgis psql -U martin_user -d martin_db << 'EOF'
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
WHERE way IS NOT NULL AND (tags->'boundary' IS NOT NULL OR tags->'place' IS NOT NULL OR tags->'admin_level' IS NOT NULL)
ON CONFLICT DO NOTHING;

SELECT 'Polygons loaded: ' || count(*) FROM polygons;
EOF
    
    echo "Data loading completed!"
    echo "Restarting Martin server to reload configuration..."
    docker-compose restart martin
    
    echo "Done! Check http://localhost:8080 to view the map"
    
else
    echo "No PBF files found in dataset/ directory"
    echo "Please add your PBF files to the dataset/ directory and run this script again"
    echo ""
    echo "Example:"
    echo "  wget -O dataset/seoul.pbf https://download.geofabrik.de/asia/south-korea-latest.osm.pbf"
    echo "  ./load-data.sh"
fi