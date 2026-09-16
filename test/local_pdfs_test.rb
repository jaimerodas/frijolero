# frozen_string_literal: true

require 'test_helper'

# The stand-in for B2 on a laptop: the same three calls, over one directory.
class LocalPdfsTest < Minitest::Test
  include TestHelpers

  KEY = 'frijolero/accounts/BBVA TDC/BBVA TDC 2608.pdf'

  def setup
    @dir = Dir.mktmpdir
    @store = Frijolero::LocalPdfs.new(@dir)
    @pdf = File.join(@dir, 'in.pdf')
    File.write(@pdf, 'pdf')
  end

  def teardown = FileUtils.remove_entry(@dir)

  def test_put_copies_the_file_under_the_key
    @store.put(KEY, @pdf)

    assert_equal 'pdf', File.read(File.join(@dir, KEY))
    assert_path_exists @pdf
  end

  def test_list_gives_the_entries_under_a_prefix_in_b2_shape
    @store.put(KEY, @pdf)
    @store.put('frijolero/accounts/AMEX/AMEX 2608.pdf', @pdf)

    entries = @store.list('frijolero/accounts/BBVA TDC/')

    keys = entries.map { |e| e[:key] }
    assert_equal [KEY], keys
    assert_equal 3, entries.first[:size]
    assert_kind_of Time, entries.first[:last_modified]
    assert_empty @store.list('frijolero/accounts/HSBC/')
  end

  def test_presigned_url_is_the_app_route_with_the_key_escaped
    assert_equal '/pdfs/frijolero/accounts/BBVA%20TDC/BBVA%20TDC%202608.pdf', @store.presigned_url(KEY)
  end

  def test_path_stays_inside_the_directory
    @store.put(KEY, @pdf)

    assert_equal File.join(@dir, KEY), @store.path(KEY)
    assert_nil @store.path('../in.pdf')
    assert_nil @store.path('frijolero/accounts/AMEX/nada.pdf')
  end
end
