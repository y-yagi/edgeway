module Edgeway
  module ImportResult
    ffi_source <<~C
      #include <stdlib.h>

      typedef struct {
        char *text;
        int capacity;
      } ImportResultBuffer;

      static const char *take_import_result(ImportResultBuffer *buffer, int length, void (*take)(char *)) {
        if (length + 1 > buffer->capacity) {
          char *grown = realloc(buffer->text, length + 1);
          if (!grown) abort();
          buffer->text = grown;
          buffer->capacity = length + 1;
        }
        take(buffer->text);
        buffer->text[length] = 0;
        return buffer->text;
      }
    C
  end
end
