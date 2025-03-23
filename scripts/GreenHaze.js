const { ethers, upgrades } = require("hardhat");

async function main() {
  // Get the contract factory
  const GreenHaze = await ethers.getContractFactory("GreenHaze");

  // Define the initialization parameters
  const owner = "0x15C944b482C537181D9947f7D1DDA225178055B5"; // Replace with the owner's address
  const router = "0xD99D1c33F9fC3444f8101754aBC46c52416550D1"; // PancakeSwap Router address (BSC Testnet)
  const stablecoin = "0x78867BbEeF44f2326bF8DDd1941a4439382EF2A7"; // BUSD address (BSC Testnet)
  const bnb = "0xae13d989daC2f0dEbFf460aC112a837C89BAa7cd"; // WBNB address (BSC Testnet)

  // Deploy the contract as a proxy
  const greenHaze = await upgrades.deployProxy(GreenHaze, [owner, router, stablecoin, bnb], {
    initializer: "initialize", // Specify the initializer function
  });

  // Wait for the deployment to complete
  await greenHaze.waitForDeployment();

  console.log("GreenHaze deployed to:", await greenHaze.getAddress());
}

// Run the deployment script
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });