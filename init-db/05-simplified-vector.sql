-- Simplified vector functions for Smart Mode (zoom 14-15)
-- 지오메트리 단순화로 성능 향상된 벡터 타일

-- Simplified polygon function
DROP FUNCTION IF EXISTS osm_polygon_simplified(integer, integer, integer);

CREATE OR REPLACE FUNCTION osm_polygon_simplified(z integer, x integer, y integer)
RETURNS bytea AS $$
DECLARE
    envelope geometry;
    tolerance float;
BEGIN
    -- 타일 경계 계산
    envelope := ST_TileEnvelope(z, x, y);
    
    -- 줌 레벨에 따른 단순화 허용 오차
    tolerance := CASE 
        WHEN z <= 10 THEN 100.0
        WHEN z <= 12 THEN 50.0
        WHEN z <= 14 THEN 20.0
        ELSE 10.0
    END;
    
    -- MVT 생성 (단순화된 지오메트리)
    RETURN ST_AsMVT(tile, 'osm_polygon_simplified', 4096, 'geom')
    FROM (
        SELECT 
            building,
            landuse,
            amenity,
            ST_SimplifyPreserveTopology(
                ST_AsMVTGeom(
                    way, 
                    envelope, 
                    4096, 
                    64,  -- 버퍼
                    true -- 클리핑
                ),
                tolerance  -- 단순화 허용오차
            ) AS geom
        FROM osm_polygon 
        WHERE way && envelope
        AND building IS NOT NULL
        AND ST_Area(way) > (tolerance * tolerance)  -- 최소 면적 필터
    ) AS tile
    WHERE geom IS NOT NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- Simplified line function  
DROP FUNCTION IF EXISTS osm_line_simplified(integer, integer, integer);

CREATE OR REPLACE FUNCTION osm_line_simplified(z integer, x integer, y integer)
RETURNS bytea AS $$
DECLARE
    envelope geometry;
    tolerance float;
BEGIN
    -- 타일 경계 계산
    envelope := ST_TileEnvelope(z, x, y);
    
    -- 줌 레벨에 따른 단순화 허용 오차
    tolerance := CASE 
        WHEN z <= 10 THEN 200.0
        WHEN z <= 12 THEN 100.0
        WHEN z <= 14 THEN 50.0
        ELSE 20.0
    END;
    
    -- MVT 생성 (단순화된 지오메트리)
    RETURN ST_AsMVT(tile, 'osm_line_simplified', 4096, 'geom')
    FROM (
        SELECT 
            highway,
            railway,
            waterway,
            ST_SimplifyPreserveTopology(
                ST_AsMVTGeom(
                    way, 
                    envelope, 
                    4096, 
                    64,  -- 버퍼
                    true -- 클리핑
                ),
                tolerance  -- 단순화 허용오차
            ) AS geom
        FROM osm_line 
        WHERE way && envelope
        AND (highway IS NOT NULL OR railway IS NOT NULL OR waterway IS NOT NULL)
        AND ST_Length(way) > tolerance  -- 최소 길이 필터
    ) AS tile
    WHERE geom IS NOT NULL;
END;
$$ LANGUAGE plpgsql STABLE;

-- Martin metadata 설정
COMMENT ON FUNCTION osm_polygon_simplified(integer, integer, integer) IS '{"minzoom": 5, "maxzoom": 15}';
COMMENT ON FUNCTION osm_line_simplified(integer, integer, integer) IS '{"minzoom": 8, "maxzoom": 15}';