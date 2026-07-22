import 'package:flutter/material.dart';

/// Clean vector "logos" for assets: a brand-coloured disc with a crisp white
/// glyph. Original + legally safe (the assets are parodies, so we evoke rather
/// than copy real trademarked logos). Falls back by sector.
class AssetLook {
  const AssetLook(this.icon, this.color);
  final IconData icon;
  final Color color;
}

const _bySymbol = <String, AssetLook>{
  // Tech
  'GOGL': AssetLook(Icons.travel_explore, Color(0xFF4285F4)),
  'ENVD': AssetLook(Icons.memory, Color(0xFF76B900)),
  'NTDO': AssetLook(Icons.sports_esports, Color(0xFFE60012)),
  'AMZM': AssetLook(Icons.shopping_cart, Color(0xFFFF9900)),
  // Energy
  'SLCT': AssetLook(Icons.solar_power, Color(0xFFF2A900)),
  'TSLR': AssetLook(Icons.electric_car, Color(0xFFE82127)),
  'XOFF': AssetLook(Icons.oil_barrel, Color(0xFF5B6770)),
  // Finance
  'GMSX': AssetLook(Icons.account_balance, Color(0xFF6C8CBF)),
  'VIZA': AssetLook(Icons.credit_card, Color(0xFF1A1F71)),
  'GEKO': AssetLook(Icons.shield, Color(0xFF2E9E5B)),
  // Consumer
  'SBRW': AssetLook(Icons.local_cafe, Color(0xFF00704A)),
  'KOKA': AssetLook(Icons.local_drink, Color(0xFFE41E2B)),
  'NIKY': AssetLook(Icons.directions_run, Color(0xFF111111)),
  // Healthcare
  'MDNA': AssetLook(Icons.biotech, Color(0xFFE10600)),
  'JNJN': AssetLook(Icons.medical_services, Color(0xFFD51900)),
  'PFZR': AssetLook(Icons.medication, Color(0xFF0093D0)),
  // Real estate
  'DWTN': AssetLook(Icons.location_city, Color(0xFF5B6770)),
  'SUBH': AssetLook(Icons.home, Color(0xFF2AA79B)),
  'MALL': AssetLook(Icons.local_mall, Color(0xFF8E44AD)),
  'WRHS': AssetLook(Icons.warehouse, Color(0xFF8D6E63)),
  'ISLE': AssetLook(Icons.beach_access, Color(0xFF00ACC1)),
  // Crypto
  'BTCN': AssetLook(Icons.currency_bitcoin, Color(0xFFF7931A)),
  'ETHR': AssetLook(Icons.diamond, Color(0xFF627EEA)),
  'SOLM': AssetLook(Icons.bolt, Color(0xFF9945FF)),
  'DOGR': AssetLook(Icons.pets, Color(0xFFC2A633)),
  // Forex — per-currency
  'EURUSD': AssetLook(Icons.euro, Color(0xFF2E5AAC)),
  'GBPUSD': AssetLook(Icons.currency_pound, Color(0xFF3F2A83)),
  'USDJPY': AssetLook(Icons.currency_yen, Color(0xFFBC002D)),
  'AUDUSD': AssetLook(Icons.public, Color(0xFF00843D)),
  'USDZAR': AssetLook(Icons.public, Color(0xFF007A4D)),
  'USDCAD': AssetLook(Icons.public, Color(0xFFD52B1E)),
  'USDINR': AssetLook(Icons.currency_rupee, Color(0xFFFF9933)),
  // Companies (scaffold)
  'CO-CAI': AssetLook(Icons.smart_toy, Color(0xFF10A37F)),
  'CO-SPCY': AssetLook(Icons.rocket_launch, Color(0xFF5B6770)),
  'CO-TED': AssetLook(Icons.construction, Color(0xFFF2A900)),
};

const _bySector = <String, AssetLook>{
  'tech': AssetLook(Icons.memory, Color(0xFF4285F4)),
  'energy': AssetLook(Icons.bolt, Color(0xFFF2A900)),
  'finance': AssetLook(Icons.account_balance, Color(0xFF6C8CBF)),
  'consumer': AssetLook(Icons.shopping_bag, Color(0xFFFF9900)),
  'healthcare': AssetLook(Icons.medical_services, Color(0xFFD51900)),
  'crypto': AssetLook(Icons.currency_bitcoin, Color(0xFFF7931A)),
  'forex': AssetLook(Icons.currency_exchange, Color(0xFF2AA79B)),
  'commercial': AssetLook(Icons.location_city, Color(0xFF5B6770)),
  'residential': AssetLook(Icons.home, Color(0xFF2AA79B)),
  'industrial': AssetLook(Icons.warehouse, Color(0xFF8D6E63)),
  'hospitality': AssetLook(Icons.beach_access, Color(0xFF00ACC1)),
  'private': AssetLook(Icons.business, Color(0xFF5B6770)),
};

AssetLook assetLook(String symbol, String sector) =>
    _bySymbol[symbol] ??
    _bySector[sector] ??
    const AssetLook(Icons.show_chart, Color(0xFF7A8794));

/// The asset's logo: a soft brand-gradient disc with a crisp white glyph.
class AssetBadge extends StatelessWidget {
  const AssetBadge(
      {super.key, required this.symbol, required this.sector, this.size = 40});

  final String symbol;
  final String sector;
  final double size;

  @override
  Widget build(BuildContext context) {
    final look = assetLook(symbol, sector);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.lerp(look.color, Colors.white, 0.18)!,
            Color.lerp(look.color, Colors.black, 0.18)!,
          ],
        ),
        boxShadow: [
          BoxShadow(
            color: look.color.withValues(alpha: 0.35),
            blurRadius: size * 0.16,
            offset: Offset(0, size * 0.06),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: Icon(look.icon, size: size * 0.55, color: Colors.white),
    );
  }
}
