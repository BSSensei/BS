name: 生成签名证书

on:
  workflow_dispatch:
    inputs:
      cert_name:
        description: '证书名称（随意填写）'
        required: true
        default: 'PermanentStore'
      cert_password:
        description: '证书密码'
        required: true
        default: 'troll'
      team_id:
        description: 'Team ID（可选，如 0000000000）'
        required: false
        default: ''
      days:
        description: '证书有效期（天）'
        required: false
        default: '3650'

jobs:
  generate:
    runs-on: macos-latest
    
    steps:
      - name: 检出代码
        uses: actions/checkout@v4

      - name: 设置执行权限
        run: chmod +x make_cert.sh

      - name: 运行证书生成脚本
        run: |
          bash make_cert.sh \
            "${{ github.event.inputs.cert_name }}" \
            "${{ github.event.inputs.cert_password }}" \
            "${{ github.event.inputs.team_id }}" \
            "${{ github.event.inputs.days }}"

      - name: 查找生成的证书文件
        id: find_cert
