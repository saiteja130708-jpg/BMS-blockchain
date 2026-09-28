import { ethers } from "hardhat";
import * as fs from "fs";
import * as path from "path";

async function main() {
    const [deployer, witness] = await ethers.getSigners();
    console.log("Deploying contracts with account:", deployer.address);

    // 1. Deploy KeyRegistry
    const KeyRegistry = await ethers.getContractFactory("KeyRegistry");
    const keyRegistry = await KeyRegistry.deploy(deployer.address);
    await keyRegistry.waitForDeployment();
    const keyRegistryAddress = await keyRegistry.getAddress();
    console.log("KeyRegistry deployed to:", keyRegistryAddress);

    // 2. Deploy CheckpointAnchor
    const CheckpointAnchor = await ethers.getContractFactory("CheckpointAnchor");
    // Using a 1-of-1 threshold for local demo purposes
    const anchor = await CheckpointAnchor.deploy(deployer.address, [witness.address], 1n);
    await anchor.waitForDeployment();
    const anchorAddress = await anchor.getAddress();
    console.log("CheckpointAnchor deployed to:", anchorAddress);

    // 3. Deploy DisputeManager
    const DisputeManager = await ethers.getContractFactory("DisputeManager");
    const disputeManager = await DisputeManager.deploy(keyRegistryAddress, anchorAddress);
    await disputeManager.waitForDeployment();
    const disputeManagerAddress = await disputeManager.getAddress();
    console.log("DisputeManager deployed to:", disputeManagerAddress);

    // 4. Export to Shared JSON
    const deploymentData = {
        network: "localhost",
        contracts: {
            KeyRegistry: {
                address: keyRegistryAddress,
                abi: JSON.parse(fs.readFileSync(path.resolve(__dirname, "../artifacts/contracts/KeyRegistry.sol/KeyRegistry.json"), "utf8")).abi
            },
            CheckpointAnchor: {
                address: anchorAddress,
                abi: JSON.parse(fs.readFileSync(path.resolve(__dirname, "../artifacts/contracts/CheckpointAnchor.sol/CheckpointAnchor.json"), "utf8")).abi
            },
            DisputeManager: {
                address: disputeManagerAddress,
                abi: JSON.parse(fs.readFileSync(path.resolve(__dirname, "../artifacts/contracts/DisputeManager.sol/DisputeManager.json"), "utf8")).abi
            }
        }
    };

    const deployDir = path.resolve(__dirname, "../deployments");
    if (!fs.existsSync(deployDir)) {
        fs.mkdirSync(deployDir);
    }

    fs.writeFileSync(
        path.join(deployDir, "localhost.json"),
        JSON.stringify(deploymentData, null, 2)
    );

    console.log("Deployment data successfully exported to deployments/localhost.json");
}

main().catch((error) => {
    console.error(error);
    process.exitCode = 1;
});
