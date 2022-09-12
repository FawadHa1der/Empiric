import configparser
import json
from pathlib import Path

import typer
from empiric.cli import SUCCESS, config, net
from empiric.cli.utils import coro
from starknet_py.contract import Contract
from starknet_py.net.gateway_client import GatewayClient

app = typer.Typer(help="Deployment commands for Publisher Registry")


@app.command()
@coro
async def deploy(config_path=config.DEFAULT_CONFIG):
    """deploy a new instance of the publisher registry"""
    gateway_url, chain_id = config.validate_config(config_path)
    client = net.init_client(gateway_url, chain_id)
    account_client = net.init_account_client(client, config_path)

    await deploy_publisher_registry(account_client, config_path)

    return SUCCESS


@app.command()
@coro
async def register_publisher(
    publisher, publisher_address, config_path=config.DEFAULT_CONFIG
):
    gateway_url, chain_id = config.validate_config(config_path)
    client = net.init_client(gateway_url, chain_id)
    account_client = net.init_account_client(client, config_path)

    config_parser = configparser.ConfigParser()
    config_parser.read(config_path)

    publisher_registry_address = int(config_parser["CONTRACTS"]["publisher-registry"])

    abi = json.loads(
        (config.COMPILED_CONTRACT_PATH / "PublisherRegistry_abi.json").read_text(
            "utf-8"
        )
    )
    contract = Contract(
        address=publisher_registry_address,
        abi=abi,
        client=account_client,
    )

    invocation = await contract.functions["register_publisher"].invoke(
        publisher, publisher_address, max_fee=int(1e16)
    )

    await invocation.wait_for_acceptance()
    typer.echo(f"response hash: {invocation.hash}")


@app.command()
@coro
async def get_all_publishers(config_path: Path = config.DEFAULT_CONFIG):
    gateway_url, chain_id = config.validate_config(config_path)
    client = net.init_client(gateway_url, chain_id)
    account_client = net.init_account_client(client, config_path)

    config_parser = configparser.ConfigParser()
    config_parser.read(config_path)
    publisher_registry_address = int(config_parser["CONTRACTS"]["publisher-registry"])
    abi = json.loads(
        (config.COMPILED_CONTRACT_PATH / "PublisherRegistry_abi.json").read_text(
            "utf-8"
        )
    )
    contract = Contract(
        address=publisher_registry_address, abi=abi, client=account_client
    )

    publishers = await contract.functions["get_all_publishers"].call()
    typer.echo(f"publishers: {publishers}")


async def deploy_publisher_registry(client: GatewayClient, config_path: Path):
    """starknet deploy --contract contracts/build/PublisherRegistry.json --inputs <ADMIN_ADDRESS>"""
    compiled = (config.COMPILED_CONTRACT_PATH / "PublisherRegistry.json").read_text(
        "utf-8"
    )

    config_parser = configparser.ConfigParser()
    config_parser.read(config_path)

    admin_address = int(config_parser["USER"]["address"])

    deployment_result = await Contract.deploy(
        client,
        compiled_contract=compiled,
        constructor_args={"admin_address": admin_address},
    )
    await deployment_result.wait_for_acceptance()
    typer.echo(f"address: {deployment_result.deployed_contract.address}")

    publisher_registry_address = deployment_result.deployed_contract.address
    config_parser["CONTRACTS"]["publisher-registry"] = str(publisher_registry_address)

    with open(config_path, "w") as f:
        config_parser.write(f)