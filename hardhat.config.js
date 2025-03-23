require("@nomicfoundation/hardhat-toolbox");
require("@openzeppelin/hardhat-upgrades");
module.exports = {
  solidity: "0.8.20",
  networks: {
    hardhat: {
      chainId: 1337,
    },
    bscTestnet: {
      url: "https://data-seed-prebsc-1-s1.binance.org:8545", // BSC Testnet RPC URL
      chainId: 97,
      accounts: ["901e69a777d493100e2676ff31fce69f4ed3bb82521b03327916c3aeec4df74b"], // Add your private key for deployment
      allowUnlimitedContractSize: true,
    },
  },
};