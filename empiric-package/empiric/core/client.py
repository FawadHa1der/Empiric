from typing import List, Optional, Tuple

from empiric.core.config import get_config
from empiric.core.entry import Entry
from empiric.core.errors import InvalidNetworkError
from empiric.core.types import ADDRESS, TESTNET, Network
from empiric.core.utils import str_to_felt
from starknet_py.contract import Contract
from starknet_py.net.gateway_client import GatewayClient


class EmpiricClient:
    oracle_address: ADDRESS
    oracle_contract: Optional[ADDRESS]

    def __init__(
        self,
        network: Network = TESTNET,
        oracle_address: Optional[ADDRESS] = None,
    ):
        self.network = network
        try:
            self.config = get_config(network)()
        except ValueError:
            raise InvalidNetworkError(f"Invalid Network name: {network}")

        self.oracle_address = oracle_address or self.config.ORACLE_CONTROLLER_ADDRESS
        self.oracle_contract = None

    async def fetch_oracle_contract(self):
        if self.oracle_contract is None:
            self.oracle_contract = await Contract.from_address(
                self.oracle_address,
                GatewayClient(self.network, self.config.CHAIN_ID),
            )

    async def get_decimals(self, key) -> int:
        await self.fetch_oracle_contract()

        if isinstance(key, str):
            pair_id = str_to_felt(key)
        elif not isinstance(key, int):
            raise TypeError("Key must be string (will be converted to felt) or integer")

        response = await self.oracle_contract.functions["get_decimals"].call(pair_id)

        return response.decimals

    async def get_value(
        self, key, aggregation_mode, sources=None
    ) -> Tuple[int, int, int, int]:
        await self.fetch_oracle_contract()

        if isinstance(key, str):
            pair_id = str_to_felt(key)
        elif not isinstance(key, int):
            raise TypeError(
                "Pair ID must be string (will be converted to felt) or integer"
            )
        if sources is None:
            response = await self.oracle_contract.functions["get_value"].call(
                pair_id, aggregation_mode
            )
        else:
            response = await self.oracle_contract.functions[
                "get_value_for_sources"
            ].call(pair_id, aggregation_mode, sources)

        return (
            response.value,
            response.decimals,
            response.last_updated_timestamp,
            response.num_sources_aggregated,
        )

    async def get_entries(self, key, sources=None) -> List[Entry]:
        await self.fetch_oracle_contract()

        if isinstance(key, str):
            pair_id = str_to_felt(key)
        elif not isinstance(key, int):
            raise TypeError(
                "Pair ID must be string (will be converted to felt) or integer"
            )
        if sources is None:
            sources = []

        response = await self.oracle_contract.functions["get_entries"].call(
            pair_id, sources
        )

        return [
            Entry(
                entry.pair_id,
                entry.value,
                entry.timestamp,
                entry.source,
                entry.publisher,
            )
            for entry in response.entries
        ]
