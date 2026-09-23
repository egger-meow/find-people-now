import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:find_people_now/auth/auth_providers.dart';
import 'package:find_people_now/generated/supadart_header.dart' show SCHOOL;
import 'package:find_people_now/match/match_providers.dart';
import 'package:find_people_now/rpc/campus_demand_rpc.dart';

void main() {
  group('Campus Demands & Filtering Providers', () {
    test('selectedTimeFilterProvider defaults to all and can be changed', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(selectedTimeFilterProvider), DemandTimeFilter.all);

      container.read(selectedTimeFilterProvider.notifier).setFilter(DemandTimeFilter.today);
      expect(container.read(selectedTimeFilterProvider), DemandTimeFilter.today);
    });

    test('selectedCampusProvider defaults to null and can be set', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(selectedCampusProvider), isNull);

      container.read(selectedCampusProvider.notifier).setCampus('光復校區');
      expect(container.read(selectedCampusProvider), '光復校區');
    });

    test('campusDemandsLastUpdatedProvider tracks timestamp', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(container.read(campusDemandsLastUpdatedProvider), isNull);

      final now = DateTime.now();
      container.read(campusDemandsLastUpdatedProvider.notifier).setTimestamp(now);
      expect(container.read(campusDemandsLastUpdatedProvider), now);
    });

    test('campusDemandsProvider polls every 30 seconds and cancels timer on subscription close', () {
      fakeAsync((async) {
        int fetchCount = 0;
        final container = ProviderContainer(
          overrides: [
            supabaseClientProvider.overrideWithValue(
              SupabaseClient(
                'http://127.0.0.1:65535',
                'test-key',
                authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
              ),
            ),
            campusDemandsFetcherProvider.overrideWithValue(
              ({required client, required school, required campus}) async {
                fetchCount++;
                return const <CampusDemandCard>[];
              },
            ),
          ],
        );
        addTearDown(container.dispose);

        // 初始無更新時間
        expect(container.read(campusDemandsLastUpdatedProvider), isNull);

        // 監聽需求資料流
        final sub = container.listen(
          campusDemandsProvider((SCHOOL.NYCU, '光復')),
          (_, _) {},
        );

        // 觸發首次 fetch
        async.elapse(const Duration(milliseconds: 1));
        expect(fetchCount, 1);
        expect(container.read(campusDemandsLastUpdatedProvider), isNotNull);

        // 經過 29 秒：未達 30 秒輪詢週期，不應再次呼叫
        async.elapse(const Duration(seconds: 29));
        expect(fetchCount, 1);

        // 經過 1 秒（累計 30 秒）：觸發第 2 次輪詢
        async.elapse(const Duration(seconds: 1));
        expect(fetchCount, 2);

        // 再經過 30 秒（累計 60 秒）：觸發第 3 次輪詢
        async.elapse(const Duration(seconds: 30));
        expect(fetchCount, 3);

        // 釋放 container，驗證 timer 被正常取消且停止輪詢
        sub.close();
        container.dispose();

        // 釋放後再經過 30 秒，不再發動輪詢呼叫
        async.elapse(const Duration(seconds: 30));
        expect(fetchCount, 3);
      });
    });
  });
}
