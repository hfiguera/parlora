# Sourced by the consumer builders. Only third-party sources and compiled
# dependencies are reusable; each consumer and Parlora package stay fresh.
case "${PARLORA_CONSUMER_MODE:-full}" in
  full|ci|smoke) ;;
  *) echo 'PARLORA_CONSUMER_MODE must be full, ci or smoke' >&2; exit 1 ;;
esac
case "${PARLORA_CONSUMER_CACHE:-}" in
  ''|/*) ;;
  *) echo 'PARLORA_CONSUMER_CACHE must be an absolute path' >&2; exit 1 ;;
esac

parlora_copy_dependencies() {
  parlora_cache_source=$1
  parlora_cache_destination=$2
  if [ -d "$parlora_cache_source/deps" ]; then
    mkdir -p "$parlora_cache_destination/deps"
    rsync -a --delete --exclude='target/' \
      "$parlora_cache_source/deps/" "$parlora_cache_destination/deps/"
  fi
  for parlora_cache_environment in dev test prod; do
    parlora_cache_libraries="_build/$parlora_cache_environment/lib"
    if [ -d "$parlora_cache_source/$parlora_cache_libraries" ]; then
      mkdir -p "$parlora_cache_destination/$parlora_cache_libraries"
      rsync -a --delete --exclude='/parlora/' --exclude='/order_desk/' \
        --exclude='/optional_backend_consumer/' \
        "$parlora_cache_source/$parlora_cache_libraries/" \
        "$parlora_cache_destination/$parlora_cache_libraries/"
    fi
  done
}

parlora_restore_consumer_cache() {
  if [ -n "${PARLORA_CONSUMER_CACHE:-}" ]; then
    parlora_copy_dependencies "$PARLORA_CONSUMER_CACHE" "$parlora_consumer"
  fi
}

parlora_save_consumer_cache() {
  if [ -n "${PARLORA_CONSUMER_CACHE:-}" ]; then
    parlora_copy_dependencies "$parlora_consumer" "$PARLORA_CONSUMER_CACHE"
  fi
}
