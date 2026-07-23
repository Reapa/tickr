import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/supabase_providers.dart';
import '../domain/company.dart';

class CompaniesRepository {
  CompaniesRepository(this._client);

  final SupabaseClient _client;

  /// The player's live company portfolio (excludes sold).
  Stream<List<Company>> watchMyCompanies(String userId) => _client
      .from('user_companies')
      .stream(primaryKey: ['id'])
      .eq('user_id', userId)
      .map((rows) => [
            for (final r in rows)
              if ((r['status'] as String?) != 'sold') Company.fromJson(r),
          ]);

  Future<List<CompanyIndustry>> fetchIndustries() async {
    final rows = await _client
        .from('company_industries')
        .select()
        .order('sort_order', ascending: true);
    return rows.map(CompanyIndustry.fromJson).toList();
  }

  Future<List<String>> fetchNamePool() async {
    final rows = await _client.from('company_name_pool').select('name');
    return [for (final r in rows) r['name'] as String];
  }

  Future<List<CompanyListing>> fetchListings() async {
    final rows = await _client
        .from('company_listings')
        .select()
        .eq('available', true)
        .order('valuation', ascending: true);
    return rows.map(CompanyListing.fromJson).toList();
  }

  /// Pending strategic decisions across the player's companies, live.
  Stream<List<CompanyDecision>> watchMyDecisions(String userId) => _client
      .from('company_decisions')
      .stream(primaryKey: ['id'])
      .eq('user_id', userId)
      .map((rows) => [
            for (final r in rows)
              if ((r['status'] as String?) == 'pending')
                CompanyDecision.fromJson(r),
          ]);

  Future<Map<String, dynamic>> decide(String decisionId, String key) =>
      _client.rpc<Map<String, dynamic>>('make_company_decision',
          params: {'p_decision': decisionId, 'p_key': key});

  Future<Map<String, dynamic>> found(
          String name, String industryId, double capital) =>
      _client.rpc<Map<String, dynamic>>('found_company', params: {
        'p_name': name,
        'p_industry': industryId,
        'p_capital': capital,
      });

  Future<Map<String, dynamic>> buy(String listingId) =>
      _client.rpc<Map<String, dynamic>>('buy_company',
          params: {'p_listing': listingId});

  Future<Map<String, dynamic>> sell(String companyId) =>
      _client.rpc<Map<String, dynamic>>('sell_company',
          params: {'p_company': companyId});
}

final companiesRepositoryProvider = Provider<CompaniesRepository>(
  (ref) => CompaniesRepository(ref.watch(supabaseProvider)),
);

final myCompaniesProvider = StreamProvider<List<Company>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <Company>[]);
  return ref.watch(companiesRepositoryProvider).watchMyCompanies(userId);
});

final myCompanyDecisionsProvider = StreamProvider<List<CompanyDecision>>((ref) {
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return Stream.value(const <CompanyDecision>[]);
  return ref.watch(companiesRepositoryProvider).watchMyDecisions(userId);
});

final companyIndustriesProvider = FutureProvider<List<CompanyIndustry>>(
  (ref) => ref.watch(companiesRepositoryProvider).fetchIndustries(),
);

final companyNamePoolProvider = FutureProvider<List<String>>(
  (ref) => ref.watch(companiesRepositoryProvider).fetchNamePool(),
);

final companyListingsProvider = FutureProvider<List<CompanyListing>>(
  (ref) => ref.watch(companiesRepositoryProvider).fetchListings(),
);
