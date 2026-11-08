import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../core/theme/app_theme.dart';
import '../../core/widgets/role_card.dart';

class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        width: double.infinity,
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppTheme.primaryGreenDark, AppTheme.primaryGreen],
            stops: [0.0, 0.4],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Column(
              children: [
                const SizedBox(height: 20),
                // Aliob logo mark
                Image.asset(
                  'assets/images/aliob_logo_mark.png',
                  width: 72,
                  height: 72,
                ),
                const SizedBox(height: 20),
                const Text('Choose Your Role',
                    style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.25,
                        letterSpacing: -0.2)),
                const SizedBox(height: 8),
                Text(
                  'Select how you want to use Aliob',
                  style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      height: 1.4,
                      color: Colors.white.withOpacity(0.85),
                      letterSpacing: 0.3),
                ),
                const SizedBox(height: 32),
                // Business roles only. A buyer does not register: the
                // dashboard is open, and checkout collects the name and phone
                // the delivery needs under an anonymous session.
                RoleCard(
                  icon: Icons.local_shipping_outlined,
                  title: 'Vehicle Provider',
                  description:
                      'Offer ride, delivery, and transportation services',
                  onTap: () => context.go('/signup/vehicle'),
                ),
                const SizedBox(height: 14),
                RoleCard(
                  icon: Icons.storefront_outlined,
                  title: 'Service Provider',
                  description:
                      'List your business, products, and professional services',
                  onTap: () => context.go('/signup/service'),
                ),
                const SizedBox(height: 32),
                // Divider
                Row(
                  children: [
                    Expanded(
                      child: Container(
                        height: 1,
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text('OR',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withOpacity(0.5),
                              letterSpacing: 1.5)),
                    ),
                    Expanded(
                      child: Container(
                        height: 1,
                        color: Colors.white.withOpacity(0.2),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                // Sign in link
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text('Already have an account? ',
                        style: TextStyle(
                            fontSize: 14, color: AppTheme.textSecondary)),
                    GestureDetector(
                      onTap: () => context.go('/login'),
                      child: const Text('Sign In',
                          style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.teal)),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
