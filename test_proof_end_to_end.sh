#!/bin/bash
set -e

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║     Proof of Claw - End-to-End Proof Generation Test          ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

cd agent

echo "📋 Test 1: Mock Proof Generation"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cargo test test_proof_generation_mock -- --nocapture
echo "✅ Mock proof generation passed"
echo ""

echo "📋 Test 2: Proof Receipt Verification"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cargo test test_verify_receipt -- --nocapture
echo "✅ Receipt verification passed"
echo ""

echo "📋 Test 3: Ledger Approval Threshold Detection"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cargo test test_ledger_approval_required -- --nocapture
echo "✅ Ledger approval detection passed"
echo ""

echo "📋 Test 4: IronClaw Trace Conversion"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
cargo test test_ironclaw_trace_conversion -- --nocapture
echo "✅ IronClaw trace conversion passed"
echo ""

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║                    ✅ ALL TESTS PASSED                         ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""
echo "📝 Summary:"
echo "  • Mock proof generation: Working"
echo "  • Receipt verification: Working"
echo "  • Ledger approval logic: Working"
echo "  • IronClaw integration: Working"
echo ""
echo "🚀 Next Steps:"
echo "  1. For production RISC Zero proofs:"
echo "     curl -L https://risczero.com/install | bash"
echo "     rzup install"
echo ""
echo "  2. Or use Boundless (recommended):"
echo "     - No local setup required"
echo "     - Decentralized proving network"
echo "     - ~\$0.30-\$30 per proof"
echo ""
echo "  3. Deploy contracts:"
echo "     cd ../contracts && forge script script/Deploy.s.sol --broadcast"
echo ""
