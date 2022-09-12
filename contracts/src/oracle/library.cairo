%lang starknet

from starkware.cairo.common.alloc import alloc
from starkware.cairo.common.bool import TRUE, FALSE
from starkware.cairo.common.cairo_builtins import HashBuiltin
from starkware.cairo.common.hash import hash2
from starkware.cairo.common.math import assert_not_equal, assert_not_zero, assert_le
from starkware.cairo.common.math_cmp import is_not_zero, is_le
from starkware.starknet.common.syscalls import get_caller_address, get_block_timestamp

from entry.structs import Checkpoint, Currency, Entry, Pair
from publisher_registry.IPublisherRegistry import IPublisherRegistry
from entry.library import Entries

const TIMESTAMP_BUFFER = 3600  # 60 minutes

#
# Storage
#
@storage_var
func Oracle_publisher_registry_address_storage() -> (publisher_registry_address : felt):
end

@storage_var
func Oracle_currencies_storage(key : felt) -> (currency : Currency):
end

@storage_var
func Oracle_pairs_storage(id : felt) -> (pair : Pair):
end

@storage_var
func Oracle_pair_id_storage(quote_currency_id, base_currency_id) -> (pair_id : felt):
end

@storage_var
func Oracle_entry_storage(key : felt, source : felt) -> (entry : Entry):
end

@storage_var
func Oracle_sources_len_storage(key : felt) -> (sources_len : felt):
end

@storage_var
func Oracle_sources_storage(key : felt, idx : felt) -> (source : felt):
end

@storage_var
func Oracle_controller_address_storage() -> (oracle_address : felt):
end

@storage_var
func Oracle__checkpoints(key : felt, index : felt) -> (res : Checkpoint):
end

@storage_var
func Oracle__checkpoint_index(key : felt) -> (index : felt):
end

@storage_var
func Oracle__sources_threshold() -> (threshold : felt):
end

#
# Events
#
@event
func UpdatedPublisherRegistryAddress(
    old_publisher_registry_address : felt, new_publisher_registry_address : felt
):
end

@event
func SubmittedEntry(new_entry : Entry):
end

@event
func SubmittedCurrency(currency : Currency):
end

@event
func UpdatedCurrency(currency : Currency):
end

@event
func SubmittedPair(pair : Pair):
end

namespace Oracle:
    #
    # Constructor
    #

    func initialize_oracle{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        publisher_registry_address : felt,
        currencies_len : felt,
        currencies : Currency*,
        pairs_len : felt,
        pairs : Pair*,
    ):
        Oracle_publisher_registry_address_storage.write(publisher_registry_address)
        _set_keys_currencies(currencies_len, currencies, 0)
        _set_keys_pairs(pairs_len, pairs, 0)
        return ()
    end

    #
    # Guards
    #

    func only_oracle_controller{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        ):
        let (caller_address) = get_caller_address()
        let (oracle_controller_address) = Oracle_controller_address_storage.read()
        if oracle_controller_address == 0:
            # Assume uninitialized
            return ()
        end
        with_attr error_message(
                "OracleImplementation: This function can only be called by the oracle controller"):
            assert caller_address = oracle_controller_address
        end
        return ()
    end

    #
    # Getters
    #

    func get_publisher_registry_address{
        syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
    }() -> (publisher_registry_address : felt):
        let (publisher_registry_address) = Oracle_publisher_registry_address_storage.read()
        return (publisher_registry_address)
    end

    func get_decimals{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        pair_id : felt
    ) -> (decimals : felt):
        let (pair) = Oracle_pairs_storage.read(pair_id)
        let (key_currency) = Oracle_currencies_storage.read(pair.base_currency_id)
        if key_currency.id == 0:
            return (0)
        end

        let key_decimals = key_currency.decimals
        return (key_decimals)
    end

    func get_value{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        key : felt, aggregation_mode : felt, sources_len : felt, sources : felt*
    ) -> (
        value : felt, decimals : felt, last_updated_timestamp : felt, num_sources_aggregated : felt
    ):
        alloc_locals

        let (entries_len, entries) = get_entries(key, sources_len, sources)

        if entries_len == 0:
            return (0, 0, 0, 0)
        end

        let (value) = Entries.aggregate_entries(entries_len, entries)
        let (decimals) = get_decimals(key)
        let (last_updated_timestamp) = Entries.aggregate_timestamps_max(entries_len, entries)
        return (value, decimals, last_updated_timestamp, entries_len)
    end

    func get_entries{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        pair_id : felt, sources_len : felt, sources : felt*
    ) -> (entries_len : felt, entries : Entry*):
        alloc_locals

        let (entries_len, entries) = get_all_entries(pair_id, sources_len, sources)
        return (entries_len, entries)
    end

    func get_entry{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        pair_id : felt, source
    ) -> (entry : Entry):
        let (entry) = Oracle_entry_storage.read(pair_id, source)
        return (entry)
    end

    func get_all_sources{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        pair_id : felt
    ) -> (sources_len : felt, sources : felt*):
        alloc_locals

        let (sources) = alloc()

        let (sources_len) = Oracle_sources_len_storage.read(pair_id)
        let (sources) = build_sources_array(pair_id, sources_len, sources, 0)
        return (sources_len, sources)
    end

    func get_latest_checkpoint_index{
        syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
    }(key : felt) -> (_idx : felt):
        let (cur_ix) = Oracle__checkpoint_index.read(key)
        return (cur_ix)
    end

    func get_latest_checkpoint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        key : felt
    ) -> (checkpoint : Checkpoint):
        let (cur_ix) = Oracle__checkpoint_index.read(key)
        let (latest_checkpoint) = Oracle__checkpoints.read(key, cur_ix - 1)
        return (latest_checkpoint)
    end

    func get_checkpoint_by_index{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        key : felt, idx : felt
    ) -> (checkpoint : Checkpoint):
        let (cur_checkpoint) = Oracle__checkpoints.read(key, idx)
        return (cur_checkpoint)
    end

    func get_sources_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        ) -> (threshold : felt):
        let (threshold) = Oracle__sources_threshold.read()
        return (threshold)
    end

    #
    # Setters
    #

    func publish_entry{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        new_entry : Entry
    ):
        alloc_locals

        let (publisher_registry_address) = get_publisher_registry_address()
        let (publisher_address) = IPublisherRegistry.get_publisher_address(
            publisher_registry_address, new_entry.publisher
        )
        let (caller_address) = get_caller_address()

        with_attr error_message("Oracle: Transaction not from publisher account"):
            assert caller_address = publisher_address
        end

        let (entry) = Oracle_entry_storage.read(new_entry.pair_id, new_entry.source)

        with_attr error_message("Oracle: Existing entry is more recent"):
            assert_le(entry.timestamp, new_entry.timestamp)
        end

        let (current_timestamp) = get_block_timestamp()
        with_attr error_message("Oracle: New entry timestamp is too far in the past"):
            assert_le(current_timestamp - TIMESTAMP_BUFFER, new_entry.timestamp)
        end

        with_attr error_message("Oracle: New entry timestamp is too far in the future"):
            assert_le(new_entry.timestamp, current_timestamp + TIMESTAMP_BUFFER)
        end

        if entry.timestamp == 0:
            # Source did not exist yet, so add to our list
            let (sources_len) = Oracle_sources_len_storage.read(new_entry.pair_id)
            Oracle_sources_storage.write(new_entry.pair_id, sources_len, new_entry.source)
            Oracle_sources_len_storage.write(new_entry.pair_id, sources_len + 1)
            tempvar syscall_ptr = syscall_ptr
            tempvar pedersen_ptr = pedersen_ptr
        else:
            tempvar syscall_ptr = syscall_ptr
            tempvar pedersen_ptr = pedersen_ptr
        end

        SubmittedEntry.emit(new_entry)
        Oracle_entry_storage.write(new_entry.pair_id, new_entry.source, new_entry)

        return ()
    end

    func publish_entries{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        new_entries_len : felt, new_entries : Entry*
    ):
        if new_entries_len == 0:
            return ()
        end

        publish_entry([new_entries])
        publish_entries(new_entries_len - 1, new_entries + Entry.SIZE)

        return ()
    end

    func _set_keys_currencies{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        keys_currencies_len : felt, keys_currencies : Currency*, idx : felt
    ):
        if idx == keys_currencies_len:
            return ()
        end

        let key_currency = keys_currencies[idx]
        Oracle_currencies_storage.write(key_currency.id, key_currency)
        _set_keys_currencies(keys_currencies_len, keys_currencies, idx + 1)

        return ()
    end

    func _set_keys_pairs{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        keys_pairs_len : felt, keys_pairs : Pair*, idx : felt
    ):
        if idx == keys_pairs_len:
            return ()
        end

        let key_pair = keys_pairs[idx]
        Oracle_pairs_storage.write(key_pair.id, key_pair)
        _set_keys_pairs(keys_pairs_len, keys_pairs, idx + 1)

        return ()
    end

    func update_publisher_registry_address{
        syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr
    }(publisher_registry_address : felt):
        let (old_publisher_registry_address) = Oracle_publisher_registry_address_storage.read()
        Oracle_publisher_registry_address_storage.write(publisher_registry_address)
        UpdatedPublisherRegistryAddress.emit(
            old_publisher_registry_address, publisher_registry_address
        )
        return ()
    end

    func add_currency{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        currency : Currency
    ):
        with_attr error_message("Oracle: currency with this key already registered"):
            let (existing_currency) = Oracle_currencies_storage.read(currency.id)
            assert existing_currency.id = 0
        end

        SubmittedCurrency.emit(currency)
        Oracle_currencies_storage.write(currency.id, currency)
        return ()
    end

    func update_currency{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        currency : Currency
    ):
        Oracle_currencies_storage.write(currency.id, currency)
        UpdatedCurrency.emit(currency)
        return ()
    end

    func add_pair{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(pair : Pair):
        let (pair_) = Oracle_pairs_storage.read(pair.id)
        with_attr error_message("Oracle: pair with this key already registered"):
            assert pair_.id = 0
        end

        SubmittedPair.emit(pair)
        Oracle_pairs_storage.write(pair.id, pair)
        Oracle_pair_id_storage.write(pair.quote_currency_id, pair.base_currency_id, pair.id)
        return ()
    end

    func set_sources_threshold{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        threshold : felt
    ):
        Oracle__sources_threshold.write(threshold)
        return ()
    end

    func set_checkpoint{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        key : felt, aggregation_mode : felt
    ):
        alloc_locals
        let (sources) = alloc()
        let (value, _decimals, last_updated_timestamp, num_sources_aggregated) = get_value(
            key, aggregation_mode, 0, sources
        )
        let (sources_threshold) = Oracle__sources_threshold.read()
        let (meets_sources_threshold) = is_le(sources_threshold, num_sources_aggregated)
        let (cur_checkpoint) = get_latest_checkpoint(key)
        let (is_new_checkpoint) = is_le(cur_checkpoint.timestamp + 1, last_updated_timestamp)
        # if both are true
        if meets_sources_threshold + is_new_checkpoint == 2:
            let checkpoint = Checkpoint(
                last_updated_timestamp, value, aggregation_mode, num_sources_aggregated
            )
            let (cur_ix) = Oracle__checkpoint_index.read(key)
            Oracle__checkpoints.write(key, cur_ix, checkpoint)
            Oracle__checkpoint_index.write(key, cur_ix + 1)
            return ()
        end
        return ()
    end

    #
    # Helpers
    #

    func get_all_entries{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        pair_id : felt, sources_len : felt, sources : felt*
    ) -> (entries_len : felt, entries : Entry*):
        alloc_locals

        let (entries : Entry*) = alloc()

        if sources_len == 0:
            let (all_sources_len, all_sources) = get_all_sources(pair_id)
            let (entries_len, entries) = build_entries_array(
                pair_id, all_sources_len, all_sources, 0, 0, entries
            )
        else:
            let (entries_len, entries) = build_entries_array(
                pair_id, sources_len, sources, 0, 0, entries
            )
        end

        return (entries_len, entries)
    end

    func build_entries_array{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        pair_id : felt,
        sources_len : felt,
        sources : felt*,
        sources_idx : felt,
        entries_idx : felt,
        entries : Entry*,
    ) -> (entries_len : felt, entries : Entry*):
        alloc_locals

        if sources_idx == sources_len:
            let entries_len = entries_idx  # 0-indexed
            return (entries_len, entries)
        end

        let source = [sources + sources_idx]
        let (entry) = Oracle_entry_storage.read(pair_id, source)
        let (is_entry_initialized) = is_not_zero(entry.timestamp)
        let not_is_entry_initialized = 1 - is_entry_initialized
        let (current_timestamp) = get_block_timestamp()
        let (is_entry_stale) = is_le(entry.timestamp, current_timestamp - TIMESTAMP_BUFFER)
        let (should_skip_entry) = is_not_zero(is_entry_stale + not_is_entry_initialized)

        if should_skip_entry == TRUE:
            let (entries_len, entries) = build_entries_array(
                pair_id, sources_len, sources, sources_idx + 1, entries_idx, entries
            )
            return (entries_len, entries)
        end

        assert [entries + entries_idx * Entry.SIZE] = entry

        let (entries_len, entries) = build_entries_array(
            pair_id, sources_len, sources, sources_idx + 1, entries_idx + 1, entries
        )
        return (entries_len, entries)
    end

    func build_sources_array{syscall_ptr : felt*, pedersen_ptr : HashBuiltin*, range_check_ptr}(
        pair_id : felt, sources_len : felt, sources : felt*, idx : felt
    ) -> (sources : felt*):
        let (new_source) = Oracle_sources_storage.read(pair_id, idx)
        assert [sources + idx] = new_source

        if idx == sources_len:
            return (sources)
        end

        build_sources_array(pair_id, sources_len, sources, idx + 1)

        return (sources)
    end
end