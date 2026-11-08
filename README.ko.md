# Chrysoberyl

제로 카피 컬럼형 바이너리 직렬화 포맷 및 SIMD 벡터 엔진 (Zero-Copy Columnar Binary Serialization & SIMD Vector Engine)

순수 Zig로 작성된 제로 카피 컬럼형(Columnar) 바이너리 직렬화 포맷이자 하드웨어 SIMD 벡터 실행 엔진입니다.

[English Documentation](README.md)

## 개요

현대 데이터 처리는 고도의 메모리 지역성과 역직렬화 오버헤드 제로화를 요구합니다. Chrysoberyl은 테이블 데이터를 64바이트 캐시 라인에 정렬된 연속 컬럼형 배열로 저장합니다. 스키마 정의를 바이트 레이아웃에서 분리함으로써, 메모리 복사 없이 마이크로초 미만의 O(1) 시간에 역직렬화를 완료하는 직접 메모리 매핑(`mmap`) 접근을 지원합니다.

## 아키텍처

- **64바이트 캐시 정렬**: L1/L2 캐시 전반에서 최적의 하드웨어 프리페칭을 보장하고 정렬되지 않은 메모리 접근 페널티를 완전히 제거합니다.
- **하드웨어 SIMD 가속**: Zig의 `@Vector(16, i32)` 및 `@reduce` 프리미티브를 활용하여 유선 속도(wire-speed) 수준의 컬럼 필터링 및 집계 연산을 수행합니다.
- **제로 카피 바이너리 포맷**: 고정 크기 헤더(`TableHeader` + `ColumnHeader[]`) 뒤에 컬럼을 순차 배치하여 로우 바이트 버퍼를 직접 슬라이싱할 수 있습니다.

## 성능

- **SIMD 리덕션 처리량**: 1,000,000행 기준 초당 5.7 GB 이상.
- **제로 카피 뷰 초기화**: 1,000,000행 기준 약 791나노초.

## 빌드 및 사용법

```bash
# 단위 테스트 실행
zig build test

# 최적화 바이너리 빌드
zig build -Doptimize=ReleaseFast

# 내장 SIMD 및 제로 카피 벤치마크 실행
./zig-out/bin/chrysoberyl bench
```

## 라이선스

MIT License. Copyright (c) 2026 Jeong Hoon Kim.
