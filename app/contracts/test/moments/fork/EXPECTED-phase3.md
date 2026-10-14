# Phase 3 targets from DyorHQ/internal: ios-app/docs/moments-analysis/economics.py ($10 threshold, 20/5/75, 10% creator alloc)

Model (exact rationals, no fees):
- rate = 3,857,142.857142857 coins per USDC; pool 38,571,428.571 coins + 10 USDC; collectors 51,428,571.429; creator 10,000,000
- opening price 2.5925926e-7 USDC/coin; FDV $25.93; collector jump +0.00%
- total collected $13.333; creator $2.667; platform $0.667; reserve $10.000

Contract (integer, terminal clamp): collectors 51,428,574.000000000000000012 short of... exactly
  sumEnt = 51428573999999999999999988 wei, pool = 38571426000000000000000012 wei, creator = 1e25 wei (identity exact)
  => collectors +2.571 coins / pool -2.571 coins vs the model = the terminal clamp's rounding (gross rounded UP to 333,334)
  creator USDC 2,666,668 / platform 666,666 / reserve 10,000,000 / total gross 13,333,334

Dump impacts (constant product on the open pool; the contract pool also charges a 0.5% LP fee on the coin input
and the hook takes 1% of the USDC output, which does not move the price):
| scenario                          | coins sold   | model out / drop  | fee-adjusted out / drop |
| creator grad-day unlock (2M)      | 2,000,000    | 0.4930 / 9.62%    | 0.4906 / 9.57%          |
| creator monthly unlock (1.6M)     | 1,600,000    | 0.3983 / 7.81%    | 0.3964 / 7.77%          |
| $1 collector full bundle          | 3,857,142.9  | 0.9091 / 17.36%   | 0.9050 / 17.28%         |
| all liquid collectors (60%)       | 30,857,142.9 | 4.4444 / 69.14%   | 4.4321 / 69.00%         |
| 10% of the liquid float           | 3,085,714.3  | 0.7407 / 14.27%   | 0.7373 / 14.20%         |
Self-graduation (one wallet collects everything, dumps 60% collectors + 20% creator = 32,857,142.9 coins at open):
  out 4.5876 USDC gross, 4.5417 after the 1% hook, drop 70.7%; plus the 2.666668 USDC creator share => ~7.21 back of 13.33 paid.
