import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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
  });
}
