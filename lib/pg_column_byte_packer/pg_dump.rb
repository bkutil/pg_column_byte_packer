module PgColumnBytePacker
  module PgDump
    def self.sort_columns_for_definition_file(path, connection:)
      sorted_dump_output = []
      current_block_start = nil
      current_block_body = []
      current_table_name = nil
      block_begin_prefix_pattern = /\ACREATE TABLE ([^\(]+) \(/
      block_end_line_pattern = /\A\);?\n\Z/

      File.foreach(path) do |line|
        if current_block_start.nil? && (create_table_match = block_begin_prefix_pattern.match(line))
          current_block_start = line
          current_block_body = []
          current_table_name = create_table_match[1]
        elsif current_block_start
          if line =~ block_end_line_pattern
            sorted_dump_output << current_block_start
            table_lines = _sort_table_lines(
              connection: connection,
              qualified_table: current_table_name,
              lines: current_block_body
            )
            table_lines = table_lines.map.with_index do |column_line, index|
              has_trailing_comma = column_line =~ /,\s*\Z/
              last_line = index == table_lines.size - 1
              if !last_line && !has_trailing_comma
                column_line.sub(/(.+)(\s*)\Z/, '\1,\2')
              elsif last_line && has_trailing_comma
                column_line.sub(/,(\s*)\Z/, '\1')
              else
                column_line
              end
            end
            sorted_dump_output.concat(table_lines)
            sorted_dump_output << line

            current_block_body = []
            current_block_start = nil
            current_table_name = nil
          else
            current_block_body << line
          end
        else
          sorted_dump_output << line
        end
      end

      File.write(path, sorted_dump_output.join)
    end

    def self._sort_table_lines(connection:, qualified_table:, lines:)
      schema, table = qualified_table.match(/([^\.]+)\.([^\.]+)/)[1..-1]

      lines.sort_by do |line|
        line = line.chomp

        # To handle the vagaries of quoted keywords as column names
        # and spaces/special characters in column names, we resort
        # to using PostgreSQL's parsing code itself on a faked
        # CREATE TABLE call with a single column; we could parse
        # the entire CREATE TABLE statement we have in the file,
        # but then we'd have to figure out a way to recreate that
        # query from the parse tree, and therein lies madness.
        line_without_comma = line[-1] == "," ? line[0..-2] : line
        fake_query = "CREATE TABLE t(#{line_without_comma});"
        parsed = begin
           PgQuery.parse(fake_query)
         rescue PgQuery::ParseError
           nil
         end

        # Ignore CONSTRAINT definitions etc.
        if parsed && (column_def = parsed.tree.stmts[0].stmt.create_stmt.table_elts[0].column_def)
          column = column_def.colname

          values = connection.select_rows(<<~SQL, "Column and Type Info").first
            SELECT
              pg_catalog.format_type(attr.atttypid, attr.atttypmod),
              typ_nsp.nspname,
              attr.attnotnull,
              attr.atthasdef,
              EXISTS (
                SELECT 1
                FROM pg_index idx
                WHERE idx.indisprimary
                  AND attr.attnum = ANY(idx.indkey)
                  AND idx.indrelid = attr.attrelid
              )
            FROM pg_catalog.pg_attribute attr
            JOIN pg_catalog.pg_type typ ON typ.oid = attr.atttypid
            JOIN pg_catalog.pg_class cls ON cls.oid = attr.attrelid
            JOIN pg_catalog.pg_namespace attr_nsp ON attr_nsp.oid = cls.relnamespace
            JOIN pg_catalog.pg_namespace typ_nsp ON typ_nsp.oid = typ.typnamespace
            WHERE attr.attname = '#{connection.quote_string(column)}'
              AND attr_nsp.nspname = '#{connection.quote_string(schema)}'
              AND cls.relname = '#{connection.quote_string(table)}'
              AND NOT attr.attisdropped
          SQL
          sql_type, type_schema, not_null, has_default, primary_key = values

          PgColumnBytePacker.ordering_key_for_column(
            connection: connection,
            name: column,
            sql_type: sql_type,
            type_schema: type_schema,
            primary_key: primary_key,
            nullable: !not_null,
            has_default: has_default
          )
        else
          # All non-column lines we want to sort at the end
          # of the table defintion statement.
          [2**32]
        end
      end
    end
  end
end
