# Max Utilization
- traders cannot utilize more than 75% of deposited liquidity
- to calculate deposited liquidity:
    - get total WETH held by contract
    - subtract held collateral
- to calculate what a trader can use (what liquidity is NOT reserved)
    - get 75% of deposited liquidity
    - subtract open interest 
    - compare

- if max utilization is exceeded, it should be impossible to open new positions, increase positions, or withdraw liquidity