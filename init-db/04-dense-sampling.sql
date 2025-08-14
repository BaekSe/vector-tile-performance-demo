-- 4픽셀 간격의 더 조밀한 샘플링 버전 (품질 우선)
DROP FUNCTION IF EXISTS raster_osm_polygons_dense(integer, integer, integer);

CREATE OR REPLACE FUNCTION raster_osm_polygons_dense(z integer, x integer, y integer)
RETURNS bytea AS $$
DECLARE
    rast raster;
    envelope_3857 geometry;
    buffered_envelope geometry;
    pixel_size_x float;
    pixel_size_y float;
    buildings geometry;
    buffer_pixels integer := 64;
    building_count integer;
    pixel_x integer;
    pixel_y integer;
    world_x float;
    world_y float;
    test_point geometry;
    px integer;
    py integer;
    tile_size integer := 512;
BEGIN
    -- 줌 레벨 제한
    IF z < 5 OR z > 21 THEN
        rast := ST_MakeEmptyRaster(tile_size, tile_size, 0, 0, 1, -1, 0, 0, 3857);
        rast := ST_AddBand(rast, 1, '8BUI'::text, 0, 0);
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
    
    -- 512x512 래스터 생성
    rast := ST_MakeEmptyRaster(tile_size, tile_size, 
                               ST_XMin(envelope_3857), ST_YMax(envelope_3857),
                               pixel_size_x, -pixel_size_y, 
                               0, 0, 3857);
    rast := ST_AddBand(rast, 1, '8BUI'::text, 0, 0);
    
    IF building_count > 0 THEN
        -- 건물 지오메트리 수집
        SELECT ST_Union(way) INTO buildings
        FROM osm_polygon 
        WHERE way && buffered_envelope
        AND building IS NOT NULL;
        
        -- 타일 경계로 클리핑
        buildings := ST_Intersection(buildings, envelope_3857);
        
        IF buildings IS NOT NULL AND NOT ST_IsEmpty(buildings) THEN
            -- 4픽셀 간격으로 6x6 블록 (더 조밀한 샘플링)
            FOR pixel_x IN 0..(tile_size-1) BY 4 LOOP
                FOR pixel_y IN 0..(tile_size-1) BY 4 LOOP
                    world_x := ST_XMin(envelope_3857) + (pixel_x + 2) * pixel_size_x;
                    world_y := ST_YMax(envelope_3857) - (pixel_y + 2) * pixel_size_y;
                    test_point := ST_SetSRID(ST_Point(world_x, world_y), 3857);
                    
                    IF ST_Intersects(buildings, test_point) THEN
                        FOR px IN pixel_x..LEAST(pixel_x+5, tile_size-1) LOOP
                            FOR py IN pixel_y..LEAST(pixel_y+5, tile_size-1) LOOP
                                rast := ST_SetValue(rast, 1, px + 1, py + 1, 255);
                            END LOOP;
                        END LOOP;
                    END IF;
                END LOOP;
            END LOOP;
            
            -- 2픽셀 오프셋으로 4x4 블록 (빈 공간 메우기)
            FOR pixel_x IN 2..(tile_size-1) BY 4 LOOP
                FOR pixel_y IN 2..(tile_size-1) BY 4 LOOP
                    world_x := ST_XMin(envelope_3857) + (pixel_x + 1) * pixel_size_x;
                    world_y := ST_YMax(envelope_3857) - (pixel_y + 1) * pixel_size_y;
                    test_point := ST_SetSRID(ST_Point(world_x, world_y), 3857);
                    
                    IF ST_Intersects(buildings, test_point) THEN
                        FOR px IN pixel_x..LEAST(pixel_x+3, tile_size-1) LOOP
                            FOR py IN pixel_y..LEAST(pixel_y+3, tile_size-1) LOOP
                                rast := ST_SetValue(rast, 1, px + 1, py + 1, 255);
                            END LOOP;
                        END LOOP;
                    END IF;
                END LOOP;
            END LOOP;
            
            -- 1픽셀 오프셋으로 2x2 블록 (더 완전한 메움)
            FOR pixel_x IN 1..(tile_size-1) BY 4 LOOP
                FOR pixel_y IN 1..(tile_size-1) BY 4 LOOP
                    world_x := ST_XMin(envelope_3857) + (pixel_x + 0.5) * pixel_size_x;
                    world_y := ST_YMax(envelope_3857) - (pixel_y + 0.5) * pixel_size_y;
                    test_point := ST_SetSRID(ST_Point(world_x, world_y), 3857);
                    
                    IF ST_Intersects(buildings, test_point) THEN
                        FOR px IN pixel_x..LEAST(pixel_x+1, tile_size-1) LOOP
                            FOR py IN pixel_y..LEAST(pixel_y+1, tile_size-1) LOOP
                                rast := ST_SetValue(rast, 1, px + 1, py + 1, 255);
                            END LOOP;
                        END LOOP;
                    END IF;
                END LOOP;
            END LOOP;
        END IF;
    END IF;
    
    RETURN ST_AsPNG(rast);
    
EXCEPTION WHEN OTHERS THEN
    rast := ST_MakeEmptyRaster(tile_size, tile_size, 0, 0, 1, -1, 0, 0, 3857);
    rast := ST_AddBand(rast, 1, '8BUI'::text, 0, 0);
    RETURN ST_AsPNG(rast);
END;
$$ LANGUAGE plpgsql STABLE;

COMMENT ON FUNCTION raster_osm_polygons_dense(integer, integer, integer) IS '{"format": "png"}';