require 'ecdsa'

COINBASE_AMOUNT = 50

class TxOut
  attr_accessor :address,
                :amount

  def initialize(address, amount)
    @address = address
    @amount = amount
  end

  def to_json(*args)
    {
      :address => address,
      :amount => amount
    }.to_json(*args)
  end
end

class TxIn
  attr_accessor :tx_out_id,
                :tx_out_index,
                :signature

  def to_json(*args)
    {
      :tx_out_id => tx_out_id,
      :tx_out_index => tx_out_index,
      :signature => signature
    }.to_json(*args)
  end
end

class Transaction
  attr_accessor :id,
                :tx_ins,
                :tx_outs

  def to_json(*args)
    {
      :id => id,
      :tx_ins => tx_ins,
      :tx_outs => tx_outs
    }.to_json(*args)
  end
end

class UnspentTxOut
  attr_accessor :tx_out_id,
                :tx_out_index,
                :address,
                :amount

  def initialize(tx_out_id, tx_out_index, address, amount)
    @tx_out_id = tx_out_id
    @tx_out_index = tx_out_index
    @address = address
    @amount = amount
  end

  def to_json(*args)
    {
      :tx_out_id => tx_out_id,
      :tx_out_index => tx_out_index,
      :address => address,
      :amount => amount
    }.to_json(*args)
  end
end

def get_transaction_id(transaction)
  tx_in_content = transaction.tx_ins
    .map { |tx_in| tx_in.tx_out_id.to_s + tx_in.tx_out_index }
    .reduce(:+)

  tx_out_content = transaction.tx_outs
    .map { |tx_out| tx_out.address.to_s + tx_out.amount }
    .reduce(:+)

  Digest::SHA256.hexdigest(tx_in_content + tx_out_content).to_s
end

def is_tx_in_valid?(tx_in, transaction, unspent_tx_outs)
  referenced_tx_out = unspent_tx_outs.find { |utxo| utxo.tx_out_id == tx_in.tx_out_id && utxo.tx_out_index == tx_in.tx_out_index}
  unless referenced_tx_out
    pp 'referenced txOut not found: ' + tx_in.to_json
  end

  address = referenced_tx_out.address

  public_key = ECDSA::Format::PointOctetString.decode(public_key_string, [address].pack('H*'))
  ECDSA.valid_signature?(public_key, transaction.id, tx_in.signature)
end

def get_tx_in_amount(tx_in, unspent_tx_outs)
  find_unspent_tx_out(tx_in.tx_out_id, tx_in.tx_out_index, unspent_tx_outs).amount
end

def find_unspent_tx_out(transaction, index, unspent_tx_outs)
  unspent_tx_outs.find { |utxo| utxo.tx_out_id == transaction.id && utxo.tx_out_index == index }
end

def is_transaction_valid?(transaction, unspent_tx_outs)
  if get_transaction_id(transaction) != transaction.id
    pp 'invalid tx id: ' + transaction.id
    return false
  end

  has_valid_tx_ins = transaction.tx_ins
    .map { |tx_in| is_tx_in_valid?(tx_in, transaction, unspent_tx_outs) }
    .reduce(:&)

  unless has_valid_tx_ins
    pp 'some of the txIns are invalid in tx: ' + transaction.id
    return false
  end

  total_tx_in_values = transaction.tx_ins
    .map { |tx_in| get_tx_in_amount(tx_in, unspent_tx_outs) }
    .reduce(:+)

  total_tx_out_values = transaction.tx_outs
    .map { |tx_out| tx_out.amount }
    .reduce(:+)

  if total_tx_in_values != total_tx_out_values
    pp 'totalTxOutValues != totalTxInValues ' + transaction.id
    return false
  end

  true
end

def sign_tx_in(transaction, tx_in_index, private_key, unspent_tx_outs)
  tx_in = transaction.tx_ins[tx_in_index]

  data_to_sign = transaction.id
  referenced_unspent_tx_out = find_unspent_tx_out(tx_in.tx_out_id, tx_in.tx_out_index, unspent_tx_outs)

  unless referenced_unspent_tx_out
    pp 'could not find referenced txOut'
    # TODO
  end

  referenced_address = referenced_unspent_tx_out.address

  public_key = ECDSA::Group::Secp256k1.generator.multiply_by_scalar(private_key)
  public_key_string = ECDSA::Format::PointOctetString.encode(public_key).unpack('H*')[0]

  unless public_key_string == referenced_address
    pp 'trying to sign an input with private key that does not match the address that is referenced in txIn'
  end

  signature = nil
  while signature.nil?
    temp_key = 1 + SecureRandom.random_number(group.order - 1)
    signature = ECDSA.sign(ECDSA::Group::Secp256k1, private_key, data_to_sign, temp_key)
  end

  ECDSA::Format::SignatureDerString.encode(signature).unpack('H*')[0]
end

def update_unspent_tx_outs(new_transactions, unspent_tx_outs)
  new_unspent_tx_outs = new_transactions
    .map { |t|
      t.tx_outs.each_with_index.map { |tx_out, index| UnspentTxOut.new(t.id, index, tx_out.address, tx_out.amount) }
    }
    .reduce(:+)

  consumed_tx_outs = new_transactions
    .map { |t| t.tx_ins }
    .reduce(:+)
    .map { |tx_in| UnspentTxOut.new(tx_in.tx_out_id, tx_in.tx_out_index, '', 0) }

  unspent_tx_outs
      .select { |utxo| !find_unspent_tx_out(utxo.tx_out_id, utxo.tx_out_index, consumed_tx_outs) }
      + new_unspent_tx_outs
end

def is_valid_coinbase_tx?(transaction, block_index)
  if transaction.nil?
    pp 'the first transaction in the block must be coinbase transaction'
    return false
  end

  if get_transaction_id(transaction) != transaction.id
    pp 'invalid coinbase tx id: ' + transaction.id
    return false
  end

  if transaction.tx_ins.length != 1
    pp 'one txIn must be specified in the coinbase transaction'
    return false
  end

  if transaction.tx_ins[0].tx_out_index != block_index
    pp 'the txIn signature in coinbase tx must be the block height'
    return false
  end

  if transaction.tx_outs.length != 1
    pp 'invalid number of txOuts in coinbase transaction'
    return false
  end

  if transaction.tx_outs[0].amount != COINBASE_AMOUNT
    pp 'invalid coinbase amount in coinbase transaction'
    return false
  end

  true
end

def has_duplicates(tx_ins)
  group = Hash.new(0)
  tx_ins.each do |tx_in|
    key =  tx_in.tx_out_id + tx_in.tx_out_index.to_s
    group[key] = group[key] + 1
  end

  group.each do |key, value|
    pp 'duplicate txIn: ' + key
    return true
  end

  false
end

def is_valid_block_transactions?(transactions, unspent_tx_outs, block_index)
  coinbase_tx = transactions[0]
  unless is_valid_coinbase_tx?(coinbase_tx, block_index)
    pp 'invalid coinbase transaction: ' + coinbase_tx.to_json
    return false
  end

  tx_ins = transactions
    .map { |tx| tx.tx_ins }
    .flatten(1)

  if has_duplicates(tx_ins)
    return false
  end

  normal_transactions = transactions.slice(1)
  normal_transactions
    .map { |tx| is_transaction_valid?(tx, unspent_tx_outs) }
    .return(:&)
end

def get_coinbase_transaction(address, block_index)
  t = Transaction.new
  tx_in = TxIn.new
  tx_in.signature = ''
  tx_in.tx_out_id = ''
  tx_in.tx_out_index = block_index

  t.tx_ins = [tx_in]
  t.tx_outs = [TxOut.new(address, COINBASE_AMOUNT)]
  t.id = get_transaction_id(t)

  t
end

def process_transactions(transactions, unspent_tx_outs, block_index)
  unless is_valid_block_transactions?(transactions, unspent_tx_outs, block_index)
    pp 'invalid block transaction'
    return nil
  end

  update_unspent_tx_outs(transactions, unspent_tx_outs)
end
