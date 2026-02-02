require_relative "base_detailer"

class BbvaDetailer < BaseDetailer
  private

  def process_transactions
    process_cash
    process_salary
    process_rav4
    process_tdc_bbva
    process_amex
    process_imss
    process_rent
    process_plata
    process_briq
    process_gas
    process_seguro_bbva
  end

  def process_cash
    @transactions
      .select { |t| t["description"].start_with? "RETIRO SIN TARJETA QR" }
      .each { |t| t["expense_account"] = "Expenses:Cash" }
  end

  def process_salary
    @transactions
      .select { |t| t["description"].include? "Letsdeel Mexi" }
      .each { |t| t["payee"] = "Change.org"; t["expense_account"] = "Income:Salary" }
  end

  def process_rav4
    @transactions
      .select { |t| t["description"].start_with? "TOYOTA FINANCIAL SER" }
      .each { |t| t["payee"] = "Toyota"; t["expense_account"] = "Liabilities:RAV4" }
  end

  def process_tdc_bbva
    @transactions
      .select { |t| t["description"].start_with? "PAGO TARJETA DE CREDITO" }
      .each { |t| t["narration"] = "Pago TDC BBVA"; t["expense_account"] = "Liabilities:BBVA" }
  end

  def process_amex
    @transactions
      .select { |t| t["description"].start_with? "AMERICAN EXPRESS" }
      .each { |t| t["narration"] = "Pago TDC Amex"; t["expense_account"] = "Liabilities:Amex" }
  end

  def process_imss
    @transactions
    .select { |t| t["description"].start_with? "CUOTAS IMSS INFONAVI" }
    .each { |t| t["payee"] = "IMSS"; t["expense_account"] = "Expenses:Taxes" }
  end

  def process_rent
    @transactions
    .select { |t| t["description"].include? "Maria Teresa Fernandez Calzada" }
    .each { |t| t["payee"] = "Maritere Fernandez"; t["expense_account"] = "Expenses:Rent:Depa" }
  end

  def process_plata
    @transactions
    .select { |t| t["description"].start_with? "SPEI ENVIADO ARCUS FI" }
    .each { |t| t["narration"] = "Pago TDC Plata"; t["expense_account"] = "Liabilities:Plata" }
  end

  def process_openbank
    @transactions
    .select { |t| t["description"].include? "646180401602956833" }
    .each { |t| t["narration"] = "Transferencia Openbank"; t["expense_account"] = "Assets:Openbank" }
  end

  def process_briq
    @transactions
    .select { |t| t["description"].include? "BRIQ FUND SAPI DE CV" }
    .each { |t| t["expense_account"] = "Assets:Other" }
  end

  def process_gas
    @transactions
    .select { |t| t["description"].include? "036180500457860889" }
    .each { |t| t["payee"] = "Roler Logistic"; t["expense_account"] = "Expenses:Utilities:Gas" }
  end

  def process_seguro_bbva
    @transactions
    .select { |t| t["description"].start_with? "META SEGURA" }
    .each { |t| t["narration"] = "Pago Seguro Ahorro BBVA"; t["expense_account"] = "Assets:MetaSegura-BBVA" }
  end
end

if $PROGRAM_NAME == __FILE__
  file = ARGV[0]
  abort("Usage: ruby amex_detailer.rb FILE.json") unless file
  BbvaDetailer.new(file).run
end
