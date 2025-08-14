-- 128x128 타일 + 벡터 스타일 통일 (초록색 stroke only)
DROP FUNCTION IF EXISTS raster_osm_polygons(integer, integer, integer);

CREATE OR REPLACE FUNCTION raster_osm_polygons(z integer, x integer, y integer)
RETURNS bytea AS $$
DECLARE
    rast raster;
    envelope_3857 geometry;
    buffered_envelope geometry;
    pixel_size_x float;
    pixel_size_y float;
    buildings geometry;
    building_outlines geometry;
    buffer_pixels integer := 16;  -- 128에 맞게 버퍼 감소
    building_count integer;
    pixel_x integer;
    pixel_y integer;
    world_x float;
    world_y float;
    world_x_inner float;
    world_y_inner float;
    test_point geometry;
    test_point_inner geometry;
    px integer;
    py integer;
    tile_size integer := 128;
BEGIN
    -- 줌 레벨 제한
    IF z < 5 OR z > 21 THEN
        rast := ST_MakeEmptyRaster(tile_size, tile_size, 0, 0, 1, -1, 0, 0, 3857);
        rast := ST_AddBand(rast, 1, '8BUI'::text, 0, 0);  -- 투명 배경
        rast := ST_AddBand(rast, 2, '8BUI'::text, 0, 0);
        rast := ST_AddBand(rast, 3, '8BUI'::text, 0, 0);
        rast := ST_AddBand(rast, 4, '8BUI'::text, 0, 0);
        RETURN ST_AsPNG(rast);
    END IF;
    
    -- 타일 경계
    SELECT ST_TileEnvelope(z, x, y) INTO envelope_3857;
    
    -- 픽셀 크기 계산
    pixel_size_x := (ST_XMax(envelope_3857) - ST_XMin(envelope_3857)) / tile_size::float;
    pixel_size_y := (ST_YMax(envelope_3857) - ST_YMin(envelope_3857)) / tile_size::float;
    
    -- 버퍼 적용
    buffered_envelope := ST_Buffer(envelope_3857, buffer_pixels * pixel_size_x);
    
    -- 건물 개수 확인
    SELECT COUNT(*) INTO building_count
    FROM osm_polygon 
    WHERE way && buffered_envelope
    AND building IS NOT NULL;
    
    -- 128x128 래스터 생성 (RGB 채널)
    rast := ST_MakeEmptyRaster(tile_size, tile_size, 
                               ST_XMin(envelope_3857), ST_YMax(envelope_3857),
                               pixel_size_x, -pixel_size_y, 
                               0, 0, 3857);
    -- RGBA 밴드 추가 (R, G, B, Alpha)
    rast := ST_AddBand(rast, 1, '8BUI'::text, 0, 0);     -- Red 채널 (배경 투명)
    rast := ST_AddBand(rast, 2, '8BUI'::text, 0, 0);     -- Green 채널 (배경 투명)
    rast := ST_AddBand(rast, 3, '8BUI'::text, 0, 0);     -- Blue 채널 (배경 투명)
    rast := ST_AddBand(rast, 4, '8BUI'::text, 0, 0);     -- Alpha 채널 (배경 투명)
    
    -- 건물이 있으면 그리기 (임시로 fill로 되돌림)
    IF building_count > 0 THEN
        -- 건물 지오메트리 수집
        SELECT ST_Union(way) INTO buildings
        FROM osm_polygon 
        WHERE way && buffered_envelope
        AND building IS NOT NULL;
        
        -- 타일 경계로 클리핑
        buildings := ST_Intersection(buildings, envelope_3857);
        
        IF buildings IS NOT NULL AND NOT ST_IsEmpty(buildings) THEN
            -- 2픽셀 간격으로 샘플링
            FOR pixel_x IN 0..(tile_size-1) BY 2 LOOP
                FOR pixel_y IN 0..(tile_size-1) BY 2 LOOP
                    world_x := ST_XMin(envelope_3857) + (pixel_x + 1) * pixel_size_x;
                    world_y := ST_YMax(envelope_3857) - (pixel_y + 1) * pixel_size_y;
                    test_point := ST_SetSRID(ST_Point(world_x, world_y), 3857);
                    
                    IF ST_Intersects(buildings, test_point) THEN
                        FOR px IN pixel_x..LEAST(pixel_x+2, tile_size-1) LOOP
                            FOR py IN pixel_y..LEAST(pixel_y+2, tile_size-1) LOOP
                                -- 초록색 설정 (RGBA 0, 170, 0, 255)
                                rast := ST_SetValue(rast, 1, px + 1, py + 1, 0);   -- Red = 0
                                rast := ST_SetValue(rast, 2, px + 1, py + 1, 170); -- Green = 170
                                rast := ST_SetValue(rast, 3, px + 1, py + 1, 0);   -- Blue = 0
                                rast := ST_SetValue(rast, 4, px + 1, py + 1, 255); -- Alpha = 255 (불투명)
                            END LOOP;
                        END LOOP;
                    END IF;
                END LOOP;
            END LOOP;
        END IF;
    END IF;
    
    RETURN ST_AsPNG(rast);
    
EXCEPTION WHEN OTHERS THEN
    -- 예외 발생 시 투명한 128x128 PNG 반환
    rast := ST_MakeEmptyRaster(tile_size, tile_size, 0, 0, 1, -1, 0, 0, 3857);
    rast := ST_AddBand(rast, 1, '8BUI'::text, 0, 0);  -- 투명 배경
    rast := ST_AddBand(rast, 2, '8BUI'::text, 0, 0);
    rast := ST_AddBand(rast, 3, '8BUI'::text, 0, 0);
    rast := ST_AddBand(rast, 4, '8BUI'::text, 0, 0);
    RETURN ST_AsPNG(rast);
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION raster_osm_polygons(integer, integer, integer) IS '{"format": "png"}';