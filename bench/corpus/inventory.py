def reserve_stock(sku):
    # reserve_stock wraps check_stock
    return check_stock(sku)

def check_stock(sku):
    return sku is not None

def release_stock(sku):
    return check_stock(sku)
